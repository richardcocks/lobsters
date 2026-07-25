# frozen_string_literal: true

module BenchOtel
  # Per-middleware spans that account only their own work.
  #
  # ---------------------------------------------------------------------------
  # The problem
  #
  # ActionDispatch::MiddlewareStack::InstrumentationProxy wraps the whole call:
  #
  #     def call(env)
  #       ActiveSupport::Notifications.instrument(EVENT_NAME, @payload) do
  #         @middleware.call(env)     # <- this includes everything downstream
  #       end
  #     end
  #
  # A Rack middleware is not one unit of work, it is two, separated by a call to
  # the next layer:
  #
  #     def call(env)
  #       ...before work...     # "in" phase
  #       status, headers, body = @app.call(env)
  #       ...after work...      # "out" phase
  #       [status, headers, body]
  #     end
  #
  # Timing the wrapper measures in + downstream + out, so every layer greedily
  # reports the cost of everything beneath it. Rack::Attack, being last, appeared
  # to cost 20ms when it cost 0.7ms; it had absorbed the entire routed app.
  #
  # ---------------------------------------------------------------------------
  # The fix, without touching anyone's `call`
  #
  # We cannot observe from outside the moment a middleware calls `@app.call`.
  # But we do not have to: the proxies nest, so *the child proxy's entry
  # timestamp is exactly that moment*. Each proxy pushes a frame and, on entry,
  # stamps its parent's frame with "your downstream started now"; on exit it
  # closes that interval. What is left after subtracting the accumulated
  # downstream interval is the layer's own work.
  #
  #     parent.call        t0 ─┐ in
  #       child.call       t1 ─┤ ← child entry stamps parent.down_open
  #         ...                │ downstream
  #       child returns    t2 ─┤ ← child exit adds (t2-t1) to parent.down_total
  #     parent returns     t3 ─┘ out
  #
  #     self = (t3-t0) - down_total = (t1-t0) + (t3-t2) = in + out
  #
  # Accumulating rather than storing a single interval keeps this correct for
  # middleware that calls downstream more than once (Rack::Attack does not, but
  # ActionDispatch::Executor and friends may re-enter on retry).
  #
  # ---------------------------------------------------------------------------
  # Span layout: flat, not nested
  #
  # Wrapping each layer in an *attached* span (in_span) reproduced the exact
  # pathology the arithmetic fixes: every middleware span became the parent of
  # everything beneath it, so the waterfall was a 30-deep staircase of
  # ~request-length bars. Instead each layer emits *detached* spans -- created
  # with explicit timestamps after its call returns, never made the current
  # context -- so they all parent to the root request span as siblings:
  #
  #     rack request (root)
  #     ├── middleware A (request)        t0..t1   ← the "in" work only
  #     ├── middleware B (request)
  #     ├── app router+controller+view    (attached; controller/AR/view nest here)
  #     ├── middleware B (response)
  #     └── middleware A (response)       t2..t3   ← the "out" work only
  #
  # Splitting request/response phases into two spans is what keeps bar length
  # honest: a single span would still stretch t0..t3 and *look* like it cost
  # the whole request even as a sibling. A layer that never calls downstream (a
  # 304, a throttle, a static file) emits one span covering its whole call.
  # Only the AppMarker keeps a live attached span, so the routed application's
  # own spans still nest somewhere sensible.
  #
  # The exclusive figures also ride along as attributes so they are queryable
  # in TraceQL directly, rather than requiring gap arithmetic over the tree by
  # hand the way the previous JSONL profiler did.
  #
  # For a layer that re-enters downstream, gaps *between* downstream calls are
  # own-work not covered by either phase span (the attributes still count them
  # in mw.self_ms).
  #
  # Known limitation: a middleware that returns a streaming/lazy body finishes
  # its `call` before the body is written, so body-generation time lands on
  # whoever consumes it rather than on the layer that produced it.
  module Middleware
    STACK_KEY = "bench_otel.mw_stack"

    # Layers we do not wrap. Rack::Events is OTel's own plumbing: it attaches
    # the root span's context in on_start and detaches in on_finish (which fires
    # at body close, after its `call` has returned). Since middleware spans are
    # now detached, wrapping it would no longer corrupt the context stack the
    # way an in_span did, but a row for OTel's own instrumentation is noise, and
    # our detached spans need Rack::Events to have already attached the root
    # context before any proxy runs so they parent to it. Every real layer sits
    # beneath it and is still instrumented.
    SKIP = ["Rack::Events"].freeze

    # Plain struct rather than Struct/OpenStruct: this allocates once per
    # middleware per request (~30/request) and shows up in allocation counts.
    class Frame
      attr_accessor :down_total, :down_open, :first_down_at, :first_down_time, :last_return_time

      def initialize
        @down_total = 0.0
        @down_open = nil
        @first_down_at = nil
        # Wall-clock twins of the monotonic stamps above, captured at the same
        # moments. The monotonic values are for arithmetic; these become the
        # explicit start/end timestamps of the detached phase spans (the SDK
        # wants Time, and monotonic values are meaningless to it).
        @first_down_time = nil
        @last_return_time = nil
      end
    end

    # Pure pass-through, appended so it becomes the innermost layer. Without it
    # the split is still arithmetically correct but attributes the entire routed
    # application to whichever middleware happens to be last, because the router
    # is not a middleware and so has no proxy to stamp the handoff:
    #
    #   Rack::Attack   total 191.48  self 191.48  downstream 0.00   <- wrong
    #
    # The marker gives the application a proxy of its own, so Rack::Attack's
    # downstream becomes measurable and the app gets its own row. Its self time
    # IS the application (router + controller + view); every layer above it is
    # genuine middleware.
    class AppMarker
      def initialize(app) = @app = app
      def call(env) = @app.call(env)
    end

    APP_NAME = "APP (router+controller+view)"

    class Proxy
      def initialize(middleware, class_name)
        @middleware = middleware
        @app = class_name == AppMarker.name
        @name = @app ? APP_NAME : class_name
        @span_name = @app ? "app router+controller+view" : "middleware #{class_name}"
      end

      def call(env)
        stack = (env[STACK_KEY] ||= [])
        parent = stack.last
        frame = Frame.new
        t0 = clock
        time0 = Time.now
        # Tell the enclosing layer that its downstream work begins here.
        if parent
          parent.down_open = t0
          parent.first_down_at ||= t0
          parent.first_down_time ||= time0
        end
        stack.push(frame)

        if @app
          # The one attached span: the routed application's own instrumentation
          # (controller, queries, renders) parents beneath it.
          BenchOtel.tracer.in_span(@span_name) do |span|
            @middleware.call(env)
          ensure
            span.add_attributes(close_frame(stack, parent, frame, t0))
          end
        else
          begin
            @middleware.call(env)
          ensure
            attrs = close_frame(stack, parent, frame, t0)
            emit_phase_spans(frame, time0, attrs)
          end
        end
      end

      private

      # Pops the frame, closes the enclosing layer's downstream interval, and
      # returns this layer's attribute hash.
      def close_frame(stack, parent, frame, t0)
        t3 = clock
        stack.pop
        if parent&.down_open
          parent.down_total += t3 - parent.down_open
          parent.down_open = nil
          parent.last_return_time = Time.now
        end

        total = t3 - t0
        self_ms = total - frame.down_total
        # No downstream call at all (short-circuit: a 304, a throttle, a
        # static file) means the whole call is this layer's own work.
        in_ms = frame.first_down_at ? frame.first_down_at - t0 : total

        BenchOtel::Metrics.record_middleware(self_ms, @name) if BenchOtel::Metrics.installed?

        {
          "mw.name" => @name,
          "mw.total_ms" => r2(total),
          "mw.self_ms" => r2(self_ms),
          "mw.downstream_ms" => r2(frame.down_total),
          "mw.in_ms" => r2(in_ms),
          "mw.out_ms" => r2(self_ms - in_ms),
          "mw.short_circuit" => frame.first_down_at.nil?
        }
      end

      # Detached spans, emitted after the fact with explicit timestamps and
      # never attached as current context, so they parent to whatever is
      # current -- the root request span -- instead of each other.
      def emit_phase_spans(frame, time0, attrs)
        tracer = BenchOtel.tracer
        time3 = Time.now

        if frame.first_down_time.nil?
          tracer.start_span(@span_name, attributes: attrs, start_timestamp: time0)
            .finish(end_timestamp: time3)
        else
          tracer.start_span("#{@span_name} (request)",
            attributes: attrs.merge("mw.phase" => "request"),
            start_timestamp: time0)
            .finish(end_timestamp: frame.first_down_time)
          tracer.start_span("#{@span_name} (response)",
            attributes: {"mw.name" => @name, "mw.phase" => "response", "mw.out_ms" => attrs["mw.out_ms"]},
            start_timestamp: frame.last_return_time)
            .finish(end_timestamp: time3)
        end
      end

      def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      def r2(f) = (f * 100).round / 100.0
    end

    class << self
      def install!
        return unless ENV["BENCH_OTEL_MIDDLEWARE"] == "1"

        # Swap in our proxy at the point Rails builds the stack. Patching
        # build_instrumented rather than InstrumentationProxy#call keeps the
        # stock proxy intact for anyone else who wants it.
        ActionDispatch::MiddlewareStack::Middleware.prepend(Module.new do
          def build_instrumented(app)
            return build(app) if BenchOtel::Middleware::SKIP.include?(inspect)
            BenchOtel::Middleware::Proxy.new(build(app), inspect)
          end
        end)

        # MiddlewareStack#build only calls build_instrumented when something is
        # listening for this event, so a subscriber is what flips instrumentation
        # on. It never fires -- we replaced the proxy that used to publish it --
        # and exists purely as that switch.
        ActiveSupport::Notifications.monotonic_subscribe(
          ActionDispatch::MiddlewareStack::InstrumentationProxy::EVENT_NAME
        ) { |*| }

        # Appended, so it is the innermost layer -- below even Rack::Attack.
        Rails.application.config.middleware.use AppMarker

        BenchOtel.warn_log "BENCH_OTEL_MIDDLEWARE=1: per-layer spans with self/downstream split"
      end
    end
  end
end
