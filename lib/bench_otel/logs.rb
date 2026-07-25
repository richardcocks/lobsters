# frozen_string_literal: true

module BenchOtel
  # OTLP logs -> the LGTM container's collector -> Loki.
  #
  # ---------------------------------------------------------------------------
  # Correlation comes for free
  #
  # OpenTelemetry::SDK::Logs::Logger#on_emit defaults `context:` to
  # Context.current and lifts trace_id/span_id off the active span:
  #
  #     current_span = OpenTelemetry::Trace.current_span(context)
  #     trace_id: trace_id || span_context&.trace_id,
  #     span_id:  span_id  || span_context&.span_id,
  #
  # So any log written during a request is automatically stamped with the trace
  # that produced it -- no MDC, no manual tagging, no log_tags config. In Grafana
  # this is what powers "jump from this log line to its trace", provided the Loki
  # datasource has a derived field on trace_id (see the provisioning file in
  # compose.prod-bench.yaml).
  #
  # Logs emitted outside a request (boot, cron, the exporter's own retries) simply
  # carry no trace id, which is correct rather than a gap.
  module Logs
    # Ruby's Logger severities are 0-5; OTel's scale is 1-24 with named bands.
    # https://opentelemetry.io/docs/specs/otel/logs/data-model/#field-severitynumber
    SEVERITY = {
      ::Logger::DEBUG => [5, "DEBUG"],
      ::Logger::INFO => [9, "INFO"],
      ::Logger::WARN => [13, "WARN"],
      ::Logger::ERROR => [17, "ERROR"],
      ::Logger::FATAL => [21, "FATAL"],
      ::Logger::UNKNOWN => [1, "TRACE"]
    }.freeze

    # Reentrancy guard. The OTLP exporter reports its own failures through
    # Rails.logger; without this, one export error logs, which emits a record,
    # which fails to export, which logs... Thread-local because the exporter runs
    # on its own thread.
    GUARD = :bench_otel_logs_emitting

    # Rails colourises SQL in its logs. The escape sequences are meaningless to
    # Loki and make log lines unreadable and unsearchable there (a query for
    # "SELECT" misses `\e[1m\e[34mSELECT`).
    ANSI = /\e\[[0-9;]*m/

    # A ::Logger-shaped sink for Rails' BroadcastLogger. It does no formatting and
    # writes no IO -- `add` hands the message to the OTel SDK, whose
    # BatchLogRecordProcessor buffers and ships it off-thread, so the request path
    # pays only the cost of building the record.
    class Sink < ::Logger
      def initialize(level)
        super(nil)                       # no logdev; nothing is written to IO
        @level = level
      end

      def add(severity, message = nil, progname = nil)
        return true if Thread.current[GUARD]
        severity ||= ::Logger::UNKNOWN
        return true if severity < level

        # ::Logger's calling convention: with no message argument, progname
        # carries the message instead. Getting this wrong ships the entire SQL
        # statement as a "logger.progname" label, which is both wrong and a
        # cardinality disaster in Loki -- every distinct query becomes a stream.
        if message.nil?
          body = block_given? ? yield : progname
          name = nil
        else
          body = message
          name = progname
        end
        return true if body.nil?

        number, text = SEVERITY.fetch(severity, SEVERITY[::Logger::UNKNOWN])
        attributes = name ? {"logger.progname" => name.to_s} : nil

        Thread.current[GUARD] = true
        BenchOtel.otel_logger&.on_emit(
          body: body.to_s.gsub(ANSI, ""),
          severity_number: number,
          severity_text: text,
          # trace_id/span_id are derived from Context.current inside on_emit.
          attributes: attributes
        )
        true
      rescue => e
        # Never let telemetry break the request. Explicitly Kernel.warn: a bare
        # `warn` inside a ::Logger subclass resolves to Logger#warn, which calls
        # back into this very method -- so the error handler would re-enter the
        # emit path (and be swallowed by GUARD) instead of reporting anything.
        # standardrb's Style/StderrPuts autofix rewrites `$stderr.puts` to `warn`
        # and introduces exactly that bug, hence the explicit receiver.
        Kernel.warn "bench_otel: log emit failed (#{e.class}: #{e.message})"
        true
      ensure
        Thread.current[GUARD] = nil
      end
    end

    class << self
      def installed? = !!@installed

      def install!
        require "opentelemetry-logs-sdk"
        require "opentelemetry-exporter-otlp-logs"

        provider = OpenTelemetry.logger_provider
        provider.add_log_record_processor(
          OpenTelemetry::SDK::Logs::Export::BatchLogRecordProcessor.new(
            OpenTelemetry::Exporter::OTLP::Logs::LogsExporter.new
          )
        )
        BenchOtel.instance_variable_set(:@otel_logger, provider.logger(name: "lobsters-bench"))

        attach!
        @installed = true
      end

      private

      # Rails 7.1+ ships BroadcastLogger, so the existing logger keeps writing to
      # its file exactly as before and OTel gets a copy. If the app has been
      # configured with a plain Logger we wrap it ourselves.
      def attach!
        # Match the app's own logger by default rather than forcing DEBUG. A
        # broadcast target applies its own level, so a hardcoded DEBUG here would
        # ship every SQL statement to Loki even when the app is at :info --
        # multiplying log volume for signal the operator deliberately turned off.
        # BENCH_OTEL_LOG_LEVEL overrides when the SQL detail is wanted.
        level = if (name = ENV["BENCH_OTEL_LOG_LEVEL"])
          ::Logger.const_get(name.upcase)
        else
          Rails.logger.level
        end

        sink = Sink.new(level)
        if Rails.logger.respond_to?(:broadcast_to)
          Rails.logger.broadcast_to(sink)
        else
          Rails.logger = ActiveSupport::BroadcastLogger.new(Rails.logger, sink)
        end

        attach_lograge!(sink)
      end

      # Lograge suppresses the stock INFO request lines (Started/Processing by/
      # Completed) and emits its own JSON line per request -- but to a dedicated
      # logger aimed at log/action.log, not Rails.logger, so the broadcast above
      # never sees the one INFO-level record a request actually produces. Wrap
      # that logger too, so the request line reaches Loki. It fires from the
      # process_action notification, synchronously inside the request, so the
      # root span is still current and the line lands trace-stamped.
      #
      # Safe to do from an initializer: Lograge.setup only reads
      # config.lograge.logger in after_initialize, which runs later. When the
      # config logger is unset lograge falls back to Rails.logger, which already
      # broadcasts to the sink -- wrapping again would ship every line twice.
      def attach_lograge!(sink)
        cfg = Rails.application.config.lograge
        return unless cfg&.enabled && cfg.logger

        cfg.logger = ActiveSupport::BroadcastLogger.new(cfg.logger, sink)
      end
    end
  end
end
