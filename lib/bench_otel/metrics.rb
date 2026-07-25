# frozen_string_literal: true

module BenchOtel
  # OTLP metrics -> the LGTM container's collector -> Prometheus.
  #
  # ---------------------------------------------------------------------------
  # Why metrics at all, when we already have traces
  #
  # Traces answer "where did this request spend its time"; metrics answer "how
  # often, and is it getting worse". The specific gap they close here is that
  # trace sampling and hand-picked trace inspection both mislead about
  # frequency -- we already burned a day on a percentile split that averaged
  # away a rare 26ms SolidCache sweep. A counter cannot average an event away.
  #
  # Exemplars are the reason this is worth wiring rather than eyeballing traces:
  # TraceBasedExemplarFilter attaches the active trace_id to sampled histogram
  # measurements, so a p99 bucket in Grafana carries pointers to real traces that
  # landed in it. That turns "the tail moved" straight into "here is a request
  # from the tail" without a TraceQL hunt.
  module Metrics
    # Rails request latency lives around 8-20ms, where the OTel default bucket
    # boundaries (which jump 0, 5, 10, 25, 50...) are far too coarse -- a p95 of
    # 11ms and a p95 of 24ms land in the same bucket. These resolve the 5-30ms
    # band properly while still catching the 100ms+ outliers we care about.
    LATENCY_BUCKETS = [1, 2, 3, 5, 7, 10, 13, 16, 20, 25, 30, 40, 60, 100, 200, 500, 1000].freeze

    # Middleware self-time is sub-millisecond for most layers, so it needs a
    # different scale entirely; ActionDispatch::Static at 1.6ms is the outlier.
    MW_BUCKETS = [0.05, 0.1, 0.25, 0.5, 1, 2, 4, 8, 16, 32, 64].freeze

    # Events whose live subscriber count we sample (see start_listener_probe!).
    # The cache trio is the prime suspect for the ops/sec climb; the rest are hot
    # paths a stray subscriber would most likely attach to. A leak shows up as a
    # monotonically rising count on whichever event it attached to.
    LISTENER_PROBE_EVENTS = %w[
      cache_read.active_support
      cache_write.active_support
      cache_delete.active_support
      cache_fetch_hit.active_support
      sql.active_record
      instantiation.active_record
      process_action.action_controller
      !render_template.action_view
    ].freeze

    class << self
      attr_reader :request_duration, :middleware_duration

      def installed? = !!@installed

      def install!
        require "opentelemetry-metrics-sdk"
        require "opentelemetry-exporter-otlp-metrics"

        provider = OpenTelemetry.meter_provider
        provider.add_metric_reader(
          OpenTelemetry::SDK::Metrics::Export::PeriodicMetricReader.new(
            exporter: OpenTelemetry::Exporter::OTLP::Metrics::MetricsExporter.new,
            # Short, because bench runs are short. A 60s default would export
            # once for a 90-second run and hide everything inside it.
            export_interval_millis: Integer(ENV.fetch("BENCH_METRIC_INTERVAL_MS", 5_000))
          )
        )

        # Sample a trace_id onto measurements so histogram buckets link to traces.
        # This is the SDK default, but it is the single feature that makes these
        # metrics worth exporting, so it is asserted rather than assumed -- a
        # stray OTEL_METRICS_EXEMPLAR_FILTER=always_off in the environment would
        # otherwise silently sever the metric->trace link.
        provider.enable_exemplar_filter(
          exemplar_filter: OpenTelemetry::SDK::Metrics::Exemplar::TraceBasedExemplarFilter
        )

        @meter = provider.meter("lobsters-bench")
        apply_buckets(provider)

        @request_duration = @meter.create_histogram(
          "http.server.request.duration", unit: "ms",
          description: "Wall time for a full request, measured outermost in the middleware stack"
        )
        @middleware_duration = @meter.create_histogram(
          "rails.middleware.self.duration", unit: "ms",
          description: "Exclusive time in one middleware layer, excluding downstream"
        )
        @gc_collections = @meter.create_counter(
          "rails.gc.collections", description: "GC runs occurring during a request"
        )
        @gc_time = @meter.create_counter(
          "rails.gc.time", unit: "ms", description: "GC milliseconds attributed to requests"
        )
        @cache_ops = @meter.create_counter(
          "rails.cache.operations", description: "SolidCache reads/writes/deletes by outcome"
        )
        @notification_listeners = @meter.create_gauge(
          "rails.notification.listeners",
          description: "Live ActiveSupport::Notifications subscriber count per event; a slow climb is a subscriber leak"
        )

        subscribe_cache!
        subscribe_listener_probe!
        @installed = true
      end

      def record_request(duration_ms, route:, method:, status:)
        @request_duration&.record(duration_ms, attributes: {
          "http.route" => route, "http.request.method" => method,
          "http.response.status_code" => status, "pid" => Process.pid.to_s
        })
      end

      def record_middleware(self_ms, name)
        @middleware_duration&.record(self_ms, attributes: {"mw.name" => name, "pid" => Process.pid.to_s})
      end

      def record_gc(runs, ms)
        return unless @gc_collections
        @gc_collections.add(runs, attributes: {"pid" => Process.pid.to_s})
        @gc_time.add(ms, attributes: {"pid" => Process.pid.to_s})
      end

      private

      # Publish live subscriber counts as a gauge, sampled once per controller
      # action. This is the direct test for the "cache ops/sec climbs while render
      # work stays flat" leak: if the same events are simply counted by an
      # ever-growing set of subscribers, that shows here as a rising count.
      # listeners_for returns every string and regexp subscriber matching the
      # event, so an accumulating subscriber surfaces on the event it attached to.
      #
      # Driven by a notification subscriber, not a background thread, precisely so
      # it survives fork: SolidQueue's worker -- where the prefill renders run and
      # a render-path subscriber leak would collect -- is forked from the puma
      # master, and a thread started at install! would not run there (the cache-op
      # counter exports from the worker for exactly this reason: it too is a
      # subscriber, inherited across fork, while a thread is not). process_action
      # fires once per rendered path (~31 per prefill cycle), ample resolution for
      # a leak that grows over hours, and records from whichever process actually
      # handled the request -- the worker included.
      def subscribe_listener_probe!
        notifier = ActiveSupport::Notifications.notifier
        ActiveSupport::Notifications.monotonic_subscribe("process_action.action_controller") do |*|
          LISTENER_PROBE_EVENTS.each do |event|
            @notification_listeners.record(
              notifier.listeners_for(event).size,
              attributes: {"event" => event, "pid" => Process.pid.to_s}
            )
          rescue => e
            # Never let the probe disturb the request it is measuring.
            Rails.logger.warn "otel: listener probe sample failed (#{e.class}: #{e.message})"
          end
        end
      end

      # Custom bucket boundaries are expressed as Views in the metrics SDK. The
      # API is pre-1.0 and has moved; if it moves again we lose bucket
      # resolution, not the metrics themselves.
      def apply_buckets(provider)
        return unless provider.respond_to?(:add_view)
        provider.add_view("http.server.request.duration",
          aggregation: OpenTelemetry::SDK::Metrics::Aggregation::ExplicitBucketHistogram.new(
            boundaries: LATENCY_BUCKETS
          ))
        provider.add_view("rails.middleware.self.duration",
          aggregation: OpenTelemetry::SDK::Metrics::Aggregation::ExplicitBucketHistogram.new(
            boundaries: MW_BUCKETS
          ))
      rescue => e
        Rails.logger.warn "otel: custom histogram buckets unavailable (#{e.class}: #{e.message}); using SDK defaults"
      end

      # Counting cache operations by outcome is the cheap, always-on version of
      # the SolidCache investigation: a delete on the fetch path means an entry
      # expired and a request paid to remove it synchronously. That is the event
      # whose *rate* we care about, and which percentiles hid.
      def subscribe_cache!
        {
          "cache_read.active_support" => "read",
          "cache_write.active_support" => "write",
          "cache_delete.active_support" => "delete"
        }.each do |event, op|
          ActiveSupport::Notifications.monotonic_subscribe(event) do |_n, _s, _f, _id, payload|
            # pid disambiguates the series per process: Puma preloads the app,
            # so all forked workers (and the SolidQueue processes) inherit one
            # SDK identity and would otherwise collide into a single Prometheus
            # series -- which zig-zags between per-process counts, and rate()
            # reads every dip as a counter reset, inflating rates ~100x.
            # Dashboards must sum over pid (sum by (key, ...) already does).
            @cache_ops.add(1, attributes: {
              "operation" => op,
              "hit" => !!payload[:hit],
              "store" => payload[:store].to_s,
              "key" => key_family(payload[:key]),
              "pid" => Process.pid.to_s
            })
          end
        end
      end

      # Collapse keys into low-cardinality families so per-key hit ratio is
      # queryable without exploding the label space: first space-delimited
      # token (drops "stories hottest=true page=1" opts), long hex runs
      # squashed before digit runs ("views/users/tree:55029686.../20095" ->
      # "views/users/tree:H/N", "c_123" -> "c_N", "aggregates_1m_86400" ->
      # "aggregates_Nm_N"). Hex first: digest digits would otherwise split
      # one digest into a distinct family per digit/letter pattern.
      def key_family(key)
        key.to_s.split(" ", 2).first.to_s.gsub(/\h{8,}/, "H").gsub(/\d+/, "N")
      end
    end
  end
end
