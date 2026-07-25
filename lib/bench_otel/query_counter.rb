# frozen_string_literal: true

module BenchOtel
  # Counts sql.active_record notifications and their :row_count with per-thread
  # integers -- no span, no event object, no payload copy -- and stamps the
  # deltas onto every span as db.query_count / db.cached_query_count and
  # db.row_count / db.cached_row_count via a SpanProcessor. This surfaces
  # queries that the ActiveRecord instrumentation gem cannot see: exists?, pluck,
  # ids, count and friends bypass _query_by_sql (the only SELECT path it patches),
  # so they produce no "<Model> query" span and otherwise show up only as
  # unattributed self time. QueryProbe closes that hole for exists? and raw
  # exec_query specifically; the counts here cover the rest.
  #
  # Counts are inclusive of child spans, like durations: render_layout's count
  # contains render_template's. Subtract children to get self counts.
  #
  # Assumes a span starts and finishes on the same thread, which holds for
  # everything Puma runs; a span crossing threads would misreport rather than
  # crash (the counter is Thread.current-local).
  module QueryCounter
    COUNT_KEY = :bench_otel_sql_count
    CACHED_KEY = :bench_otel_sql_cached_count
    ROWS_KEY = :bench_otel_sql_rows
    CACHED_ROWS_KEY = :bench_otel_sql_cached_rows

    class << self
      def count = Thread.current[COUNT_KEY] || 0

      def cached_count = Thread.current[CACHED_KEY] || 0

      def rows = Thread.current[ROWS_KEY] || 0

      def cached_rows = Thread.current[CACHED_ROWS_KEY] || 0

      def subscribe!
        ActiveSupport::Notifications.monotonic_subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
          next if payload[:name] == "SCHEMA"
          count_key, rows_key = payload[:cached] ? [CACHED_KEY, CACHED_ROWS_KEY] : [COUNT_KEY, ROWS_KEY]
          Thread.current[count_key] = (Thread.current[count_key] || 0) + 1
          # The sqlite3 adapter reports the materialized result's length: rows
          # returned, not rows scanned. The query cache sets it on hits too.
          Thread.current[rows_key] = (Thread.current[rows_key] || 0) + (payload[:row_count] || 0)
        end
      end
    end

    class Processor
      def on_start(span, _parent_context)
        span.instance_variable_set(:@bench_sql_at_start,
          [QueryCounter.count, QueryCounter.cached_count, QueryCounter.rows, QueryCounter.cached_rows])
      end

      def on_finish(span)
        at_start = span.instance_variable_get(:@bench_sql_at_start) or return
        queries = QueryCounter.count - at_start[0]
        cached = QueryCounter.cached_count - at_start[1]
        rows = QueryCounter.rows - at_start[2]
        cached_rows = QueryCounter.cached_rows - at_start[3]
        return if queries.zero? && cached.zero?

        # The SDK offers no supported way to mutate a span after finish, so this
        # reaches into @attributes. Runs before the batch processor snapshots the
        # span (processors fire in registration order and this one is added
        # first); dup handles the SDK freezing attributes at finish.
        # @total_recorded_attributes must be bumped in step: the OTLP encoder
        # derives dropped_attributes_count from (total - size), and a negative
        # result is a protobuf error that kills the export of the whole batch.
        attrs = span.instance_variable_get(:@attributes) || {}
        attrs = attrs.dup if attrs.frozen?
        added = 0
        # Row counts are stamped whenever their query count is, including zero:
        # "3 queries, 0 rows" (exists?/misses) is signal, not absence of data.
        (attrs["db.query_count"] = queries; attrs["db.row_count"] = rows; added += 2) if queries > 0
        (attrs["db.cached_query_count"] = cached; attrs["db.cached_row_count"] = cached_rows; added += 2) if cached > 0
        span.instance_variable_set(:@attributes, attrs)
        span.instance_variable_set(:@total_recorded_attributes,
          (span.instance_variable_get(:@total_recorded_attributes) || 0) + added)
      end

      def force_flush(timeout: nil) = 0

      def shutdown(timeout: nil) = 0
    end
  end
end
