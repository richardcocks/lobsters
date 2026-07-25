# frozen_string_literal: true

# OpenTelemetry benchmark harness: traces, metrics and logs, all correlated.
#
# This is a measurement tool, not production code. Every entry point is gated on
# BENCH_OTEL=1 and the whole thing degrades to a warning if the gems are absent,
# so it is inert in any environment that has not deliberately opted in. The gems
# live in the git-excluded Gemfile.bench, selected via BUNDLE_GEMFILE.
#
# Wired up from config/initializers/production.rb (gitignored), which is a
# one-liner; the substance lives here so it is tracked, reviewable and diffable.
#
# ---------------------------------------------------------------------------
# Why this exists rather than just `c.use_all`
#
# The stock Rails instrumentation leaves two holes:
#
#   1. ActionPack renames the root Rack span after the matched route instead of
#      emitting its own controller span, so middleware and controller fuse into
#      a single bucket and anything that is neither a query nor a template
#      render surfaces as unattributed "self" time on the root.
#
#   2. ActionDispatch's own middleware instrumentation wraps the entire
#      `@middleware.call(env)`, which includes the downstream call. Every layer
#      therefore reports the cost of everything beneath it. The outermost
#      middleware always looks like the most expensive one, and the innermost
#      silently absorbs the whole routed application.
#
# BenchOtel::Middleware fixes (2); the ActiveSupport event subscriptions below
# fix (1).
#
# ---------------------------------------------------------------------------
# Signal correlation
#
#   logs  -> traces  automatic. The logs SDK defaults `context:` to
#                    Context.current and lifts trace_id/span_id off the active
#                    span, so any log emitted during a request carries them.
#   metrics -> traces via exemplars. TraceBasedExemplarFilter attaches a
#                    trace_id to sampled histogram measurements, which is what
#                    lets you click from a latency spike to a trace that caused
#                    it. This is the piece that makes the metrics worth having:
#                    percentiles hide rare discrete events (see the SolidCache
#                    sweep finding), and an exemplar is a pointer to the actual
#                    slow request rather than an average over it.
module BenchOtel
  class << self
    attr_reader :tracer, :meter, :otel_logger

    def enabled? = @enabled

    def install!
      return if @installed
      @installed = true

      require "opentelemetry/sdk"
      require "opentelemetry/exporter/otlp"
      require "opentelemetry/instrumentation/rails"
      require_relative "bench_otel/query_counter"
      require_relative "bench_otel/noise_sampler"

      OpenTelemetry::SDK.configure do |c|
        # Gotcha (configurator.rb#configure_span_processors): supplying ANY custom
        # span processor replaces the default env-configured OTLP exporter rather
        # than adding to it, so the exporter must be re-registered explicitly.
        # Order matters: the counter's on_finish must write its attributes before
        # the batch processor sees the span.
        c.add_span_processor(QueryCounter::Processor.new)
        c.add_span_processor(
          OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(
            OpenTelemetry::Exporter::OTLP::Exporter.new
          )
        )
        c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "lobsters")
        # Installs every instrumentation whose gem is present. Gemfile.bench only
        # pulls the Rails family, so this stays scoped to action_pack,
        # action_view, active_record, active_support, active_job and rack.
        #
        # url_quantization: Rack names the root span bare "GET" per semconv when
        # nothing downstream supplies a route, which is every static asset --
        # ActionPack renames the span to "GET /about" etc. only for routed
        # requests, so those are unaffected. Raw paths are a span-name
        # cardinality sin in production; in a bench harness, being able to see
        # *which* asset is worth it.
        c.use_all("OpenTelemetry::Instrumentation::Rack" => {
          url_quantization: ->(path, env) { "#{env["REQUEST_METHOD"]} #{path}" }
        })
      end

      # Replaces the env-configured always_on AFTER configure: same behavior for
      # every parented span and every legitimate root, but SolidQueue's
      # background-poll roots are dropped (see noise_sampler.rb).
      OpenTelemetry.tracer_provider.sampler =
        OpenTelemetry::SDK::Trace::Samplers.parent_based(root: NoiseSampler.new)

      @tracer = OpenTelemetry.tracer_provider.tracer("lobsters-bench")
      @enabled = true

      QueryCounter.subscribe!
      subscribe_events!

      # Required unconditionally so the constants always resolve. Only install!
      # touches the pre-1.0 gems, so a metrics gem that fails to load leaves
      # Metrics.installed? false rather than leaving BenchOtel::Metrics undefined
      # and raising NameError from the middleware hot path.
      require_relative "bench_otel/metrics"
      require_relative "bench_otel/logs"
      require_relative "bench_otel/middleware"
      require_relative "bench_otel/request_probe"
      require_relative "bench_otel/sponge_probe"
      require_relative "bench_otel/query_probe"
      require_relative "bench_otel/write_probe"
      require_relative "bench_otel/profile_probe"

      install_optional("metrics") { Metrics.install! } unless ENV["BENCH_OTEL_METRICS"] == "0"
      install_optional("logs") { Logs.install! } unless ENV["BENCH_OTEL_LOGS"] == "0"
      install_optional("middleware") { Middleware.install! }
      install_optional("sponge") { SpongeProbe.install! }
      install_optional("query_probe") { QueryProbe.install! }
      install_optional("write_probe") { WriteProbe.install! }
      install_optional("profile_probe") { ProfileProbe.install! }
      RequestProbe.install!

      warn_log "BENCH_OTEL=1: traces#{" +metrics" if Metrics.installed?}" \
        "#{" +logs" if Logs.installed?} -> #{ENV["OTEL_EXPORTER_OTLP_ENDPOINT"]}"
    rescue LoadError => e
      Rails.logger.error "BENCH_OTEL=1 but OTel gems are missing (#{e.message}). " \
        "Is BUNDLE_GEMFILE=Gemfile.bench set?"
    end

    def warn_log(msg) = Rails.logger.warn(msg)

    private

    # Each signal is optional and independently gated: a pre-1.0 metrics or logs
    # gem breaking must not take tracing (the signal we actually rely on) down
    # with it.
    def install_optional(name)
      yield
    rescue => e
      Rails.logger.warn "otel: #{name} disabled (#{e.class}: #{e.message})"
    end

    # OTel's ActiveSupport instrumentation can promote *any* notification to a
    # span, so the fix for the controller-span hole is simply to name the events
    # Rails already publishes.
    #
    # process_middleware.action_dispatch is deliberately absent: BenchOtel::
    # Middleware emits those spans itself with a correct self/downstream split,
    # and subscribing here as well would double-instrument every layer.
    def subscribe_events!
      %w[
        start_processing.action_controller
        process_action.action_controller
        write_page.action_controller
        expire_page.action_controller
        cache_read.active_support
        cache_write.active_support
        cache_delete.active_support
        cache_fetch_hit.active_support
        instantiation.active_record
        hydrate.user_tree_row
      ].each do |event|
        OpenTelemetry::Instrumentation::ActiveSupport.subscribe(@tracer, event)
      rescue => e
        Rails.logger.warn "otel: could not subscribe #{event}: #{e.class}"
      end
    end
  end
end
