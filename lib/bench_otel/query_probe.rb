# frozen_string_literal: true

module BenchOtel
  # Spans for query paths the ActiveRecord instrumentation gem cannot see. The
  # gem patches _query_by_sql, the SELECT path behind find/where/to_a, so those
  # surface as "<Model> query" spans -- but exists? goes through the adapter
  # directly and raw connection.exec_query never touches the model layer at all.
  # QueryCounter still *counts* both (they fire sql.active_record), but without
  # these probes their time is unattributed self time on the enclosing span.
  #
  # pluck/ids/count share the same hole and remain span-less; they stay visible
  # only via db.query_count. Add a probe here if one of them turns up hot.
  module QueryProbe
    # Relation#exists? covers Model.exists? (Querying delegates to :all),
    # relation chains and CollectionProxy. The SQL itself isn't in scope at this
    # layer; the span's QueryCounter stamps (db.query_count et al) distinguish a
    # real probe query from an already-loaded relation answering from memory.
    module ExistsProbe
      def exists?(...)
        BenchOtel.tracer.in_span("#{klass.name} exists?") { super }
      end
    end

    # eager_load relations skip _query_by_sql entirely: exec_queries sees
    # eager_loading? and hands the join-dependency arel straight to
    # connection.select_all, so the (often giant) LEFT JOIN query gets no span
    # -- only the instantiation.active_record event afterwards. Wrap just the
    # eager-loading branch; plain relations keep their gem-provided span.
    module EagerLoadProbe
      def exec_queries(...)
        return super unless eager_loading?
        BenchOtel.tracer.in_span("#{klass.name} eager_load query",
          attributes: {"db.statement" => to_sql}) { super }
      end
    end

    # Public exec_query is only a caller-facing wrapper in Rails 7.1+ -- the
    # adapter's own reads go through internal_exec_query -- so this catches
    # exactly the hand-written-SQL call sites (FlaggedCommenters, the /u tree)
    # and cannot double-span ordinary AR queries.
    module ExecQueryProbe
      def exec_query(sql, name = "SQL", *args, **kwargs)
        BenchOtel.tracer.in_span("exec_query #{name}",
          attributes: {"db.statement" => sql}) { super }
      end
    end

    class << self
      def install!
        # Framework classes, not autoloaded: a one-shot prepend survives
        # code reloading, so no to_prepare dance (contrast SpongeProbe).
        ActiveSupport.on_load(:active_record) do
          ActiveRecord::Relation.prepend(QueryProbe::ExistsProbe)
          ActiveRecord::Relation.prepend(QueryProbe::EagerLoadProbe)
          ActiveRecord::ConnectionAdapters::AbstractAdapter.prepend(QueryProbe::ExecQueryProbe)
        end
      end
    end
  end
end
