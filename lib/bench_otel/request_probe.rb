# frozen_string_literal: true

module BenchOtel
  # Outermost probe: annotates the root span with GC deltas and feeds the request
  # latency histogram.
  #
  # GC.stat(:time) is cumulative process-wide GC milliseconds, so a delta across
  # the request is exactly what this request lost to collection. This is the test
  # that separates the two candidate explanations for scattered stalls in
  # otherwise pure-Ruby stretches:
  #
  #   gc.time_ms tracks the gaps        -> garbage collection
  #   gc.time_ms ~ 0 on a slow request  -> the VM descheduled the process
  #
  # (It has already answered that question here -- 0 collections across 400
  # sampled requests -- but it stays because it is the cheapest way to keep GC
  # ruled out as the ground shifts under later changes.)
  class RequestProbe
    def initialize(app) = @app = app

    def call(env)
      t = GC.stat
      c0, m0, a0, tm0 = t[:count], t[:major_gc_count], t[:total_allocated_objects], t[:time]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      status = 0

      begin
        result = @app.call(env)
        status = result[0]
        result
      ensure
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - started
        t = GC.stat
        runs = t[:count] - c0
        gc_ms = t[:time] - tm0

        span = OpenTelemetry::Trace.current_span
        if span&.recording?
          span.add_attributes(
            "gc.count" => runs,
            "gc.major_count" => t[:major_gc_count] - m0,
            "gc.time_ms" => gc_ms,
            "allocations" => t[:total_allocated_objects] - a0
          )
          # Visible marker in the waterfall for requests that lost time to GC,
          # so they can be spotted without opening every root span's attributes.
          # A span event was too subtle -- a one-pixel tick at the bar's edge --
          # so this is a child span whose *length* is the measured GC time. Its
          # *position* is synthetic: right-aligned at the end of the request,
          # because GC.stat deltas cannot say when inside the request the pauses
          # landed, only how much time they took in total.
          if gc_ms > 0
            gc_end = Time.now
            BenchOtel.tracer.start_span("GC (position unknown)",
              attributes: {
                "gc.count" => runs,
                "gc.major_count" => t[:major_gc_count] - m0,
                "gc.time_ms" => gc_ms
              },
              start_timestamp: gc_end - (gc_ms / 1000.0))
              .finish(end_timestamp: gc_end)
          end
        end

        if BenchOtel::Metrics.installed?
          BenchOtel::Metrics.record_request(elapsed, route: route_for(env),
            method: env["REQUEST_METHOD"], status: status)
          BenchOtel::Metrics.record_gc(runs, gc_ms)
        end
      end
    end

    private

    # The route *pattern*, never the raw path. PATH_INFO would put every story id
    # into the metric's label set and blow up Prometheus cardinality; the pattern
    # collapses /s/abc123 and /s/def456 to a single series.
    def route_for(env)
      env["action_dispatch.route_uri_pattern"] || "(unmatched)"
    end

    class << self
      def install!
        # Immediately inside OTel's own Rack::Events handler, which sits at the
        # very top of the stack -- so the GC delta and the duration cover the
        # whole request (including the outer middleware, where the largest gaps
        # appeared) while still running inside the root span, which is what makes
        # current_span resolve to it.
        Rails.application.config.middleware.insert_after Rack::Events, RequestProbe
      rescue => e
        Rails.logger.warn "otel: could not place RequestProbe after Rack::Events (#{e.class}); " \
          "falling back to outermost, GC will be attributed to no span"
        Rails.application.config.middleware.unshift RequestProbe
      end
    end
  end
end
