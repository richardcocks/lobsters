# typed: false

require "rails_helper"

# These specs document a performance characteristic rather than behaviour.
#
# TrafficHelper.cache_traffic! runs every 5 minutes (config/recurring.yml) inside
# the Puma processes (SOLID_QUEUE_IN_PUMA), and its queries filter votes on
# updated_at and comments on created_at. Neither column is indexed, so both are
# full table scans of the two largest tables in the schema.
#
# `stories` is the control: it filters on created_at too, but has
# index_stories_on_created_at, so the same query shape uses an index. That
# isolates the missing indexes as the cause rather than the query shape.
#
# The plan is structural -- there is no index on those columns for SQLite to
# choose -- so these assertions don't depend on row counts or timing.
describe TrafficHelper do
  # SQLite reworded query plans in 3.36 ("SCAN TABLE t" -> "SCAN t"), so match
  # both forms rather than pinning to whichever version is bundled today.
  def scans_table(name)
    a_string_matching(/\ASCAN (TABLE )?#{name}\b/)
  end

  def uses_index_on(name)
    a_string_matching(/\b#{name}\b.*USING (COVERING )?INDEX/)
  end

  # Capture the SQL the helper actually issues, so these specs can't drift from
  # the implementation the way a hand-copied query would.
  def sql_issued_by
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] unless payload[:name] == "SCHEMA"
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def plan_for(&)
    sql = sql_issued_by(&).find { |q| q.include?("n_votes") }
    raise "did not capture the expected query" if sql.nil?

    ActiveRecord::Base.connection
      .select_all("EXPLAIN QUERY PLAN #{sql}")
      .to_a
      .map { |row| row["detail"] }
  end

  shared_examples "scans the unindexed timestamp columns" do
    it "scans votes, which has no index on updated_at" do
      expect(plan).to include(scans_table("votes"))
      expect(plan).not_to include(uses_index_on("votes"))
    end

    it "scans comments, which has no index on created_at" do
      expect(plan).to include(scans_table("comments"))
      expect(plan).not_to include(uses_index_on("comments"))
    end

    # control: same predicate shape against an indexed column
    it "uses an index for stories, which does index created_at" do
      expect(plan).to include(uses_index_on("stories"))
    end
  end

  describe ".traffic_range" do
    let(:plan) { plan_for { described_class.traffic_range } }

    include_examples "scans the unindexed timestamp columns"
  end

  describe ".current_activity" do
    let(:plan) { plan_for { described_class.current_activity } }

    include_examples "scans the unindexed timestamp columns"
  end
end
