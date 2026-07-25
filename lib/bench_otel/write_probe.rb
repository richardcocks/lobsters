# frozen_string_literal: true

module BenchOtel
  # Spans for the SQL write paths. Reads are covered by the AR instrumentation
  # gem (_query_by_sql) plus QueryProbe, but INSERT/UPDATE/DELETE reach the
  # adapter through exec_insert/exec_update/exec_delete and never touch either,
  # so a save's write -- and any writer-lock wait or commit fsync -- was
  # unattributed self time on the enclosing span (User#save showed
  # db.query_count 8 with only 6 child spans).
  module WriteProbe
    # The arel write path (insert/update/delete behind _create_record,
    # _update_record and destroy) funnels through these three public methods,
    # as do hand-written exec_update/exec_delete call sites. The name argument
    # is Rails' own statement label ("User Update", "User Create"), so spans
    # match the names QueryCounter already logs.
    module ExecWriteProbe
      def exec_insert(sql, name = nil, binds = [], pk = nil, sequence_name = nil, returning: nil)
        BenchOtel.tracer.in_span(name || "SQL insert",
          attributes: {"db.statement" => sql}) { super }
      end

      def exec_update(sql, name = nil, binds = [])
        BenchOtel.tracer.in_span(name || "SQL update",
          attributes: {"db.statement" => sql}) { super }
      end

      def exec_delete(sql, name = nil, binds = [])
        BenchOtel.tracer.in_span(name || "SQL delete",
          attributes: {"db.statement" => sql}) { super }
      end
    end

    # SQLite serializes writers: BEGIN IMMEDIATE is where a competing writer
    # blocks (busy_timeout spins here), COMMIT is where the WAL fsync lands.
    # Rails materializes transactions lazily, so the begin span appears just
    # before the first write statement, not where the transaction block opened
    # -- lock-wait time is the begin span, durability time is the commit span.
    module TransactionProbe
      def begin_db_transaction
        BenchOtel.tracer.in_span("TRANSACTION begin immediate") { super }
      end

      def begin_isolated_db_transaction(isolation)
        BenchOtel.tracer.in_span("TRANSACTION begin #{isolation}") { super }
      end

      def commit_db_transaction
        BenchOtel.tracer.in_span("TRANSACTION commit") { super }
      end

      def exec_rollback_db_transaction
        BenchOtel.tracer.in_span("TRANSACTION rollback") { super }
      end
    end

    class << self
      def install!
        ActiveSupport.on_load(:active_record) do
          ActiveRecord::ConnectionAdapters::AbstractAdapter.prepend(WriteProbe::ExecWriteProbe)
        end
        # The sqlite3 adapter overrides the transaction methods, so a prepend
        # on AbstractAdapter would sit behind them in the lookup chain and
        # never fire; it has to land on the adapter class itself.
        ActiveSupport.on_load(:active_record_sqlite3adapter) do
          prepend WriteProbe::TransactionProbe
        end
      end
    end
  end
end
