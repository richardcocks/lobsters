# frozen_string_literal: true

module BenchOtel
  # On-demand per-request stackprof capture, for decomposing pure-Ruby gaps
  # that spans cannot see into (the 27ms between the last validation query and
  # the UPDATE on POST /settings reproduces in the web process but not in a
  # faithful runner replication, so it has to be profiled in situ).
  #
  # Enable with BENCH_PROFILE_PATH=/settings; every request whose PATH_INFO
  # matches exactly is profiled wall-mode at 100us. Each capture goes two
  # places:
  #   - Pyroscope (BENCH_PYROSCOPE_URL), collapsed format via the legacy
  #     /ingest API, tagged {path, method, trace_id} -- so the flamegraph for
  #     a specific Tempo trace is one label filter away in Grafana.
  #   - tmp/profiles/*.dump + .meta.json on the bind mount: the raw marshal
  #     keeps per-sample timestamp deltas, which the folded upload discards,
  #     so offline span-aligned analysis stays possible.
  class ProfileProbe
    # StackProf is process-global; a second concurrent request cannot start a
    # nested capture, so it just passes through unprofiled.
    LOCK = Mutex.new

    def initialize(app) = @app = app

    def call(env)
      return @app.call(env) unless env["PATH_INFO"] == ENV["BENCH_PROFILE_PATH"]
      return @app.call(env) unless LOCK.try_lock

      begin
        meta = {
          started_at_unix_ns: (Process.clock_gettime(Process::CLOCK_REALTIME) * 1e9).to_i,
          method: env["REQUEST_METHOD"],
          path: env["PATH_INFO"],
          trace_id: OpenTelemetry::Trace.current_span.context.hex_trace_id
        }
        result = nil
        interval = ENV.fetch("BENCH_PROFILE_INTERVAL_US", "250").to_i
        data = StackProf.run(mode: :wall, interval: interval, raw: true) do
          result = @app.call(env)
        end
        finished_ns = (Process.clock_gettime(Process::CLOCK_REALTIME) * 1e9).to_i
        # Both ends in realtime: raw_timestamp_deltas under-count around missed
        # samples (sum(deltas) can be far short of last-first in
        # raw_sample_timestamps), so offline alignment anchors the monotonic
        # timestamps against this pair instead of accumulating deltas.
        meta[:finished_at_unix_ns] = finished_ns
        meta[:interval_us] = interval
        # Everything downstream of the capture -- Marshal, the folded
        # conversion, file writes, the Pyroscope POST -- runs off-thread.
        # Measured cost of doing it inline: a 200-280ms "ProfileProbe
        # (response)" span on every profiled request (drvfs bind-mount write +
        # fold churn), plus a major GC provoked by the allocation spike. The
        # GVL still pays for the background work, but the profiled request's
        # own waterfall no longer does.
        Thread.new { persist(data, meta, finished_ns) }
        result
      ensure
        LOCK.unlock
      end
    end

    private

    def persist(data, meta, finished_ns)
      # Container-local tmp, NOT the repo bind mount: a raw dump is ~1.4MB and
      # drvfs writes are ~30x slow. Dumps die with the container; the durable
      # copy is the Pyroscope upload. Retrieve a dump for offline analysis
      # with `podman exec` / `podman cp` while the container lives.
      dir = ENV.fetch("BENCH_PROFILE_DIR", "/tmp/profiles")
      FileUtils.mkdir_p(dir)
      base = File.join(dir, Time.now.strftime("%H%M%S.%L") +
        "-#{meta[:method]}#{meta[:path].tr("/", "_")}")
      File.binwrite("#{base}.dump", Marshal.dump(data))
      File.write("#{base}.meta.json", JSON.generate(meta))

      folded = fold(data)
      push_to_pyroscope(folded, meta, finished_ns) unless folded.empty?
    rescue => e
      Rails.logger.warn "profile_probe: persist failed (#{e.class}: #{e.message})"
    end

    # stackprof raw format: [stack_len, frame_ids..., sample_count] repeating.
    # Stacks are root-first, which is exactly the collapsed/folded order.
    def fold(data)
      frames = data[:frames]
      raw = data[:raw] or return ""
      lines = Hash.new(0)
      i = 0
      while i < raw.length
        len = raw[i]
        # ";" delimits frames in folded format, so it cannot appear in a name.
        stack = raw[i + 1, len].map { |id| frames[id][:name].tr(";", ":") }
        lines[stack.join(";")] += raw[i + 1 + len]
        i += len + 2
      end
      lines.map { |stack, count| "#{stack} #{count}" }.join("\n")
    end

    def push_to_pyroscope(folded, meta, finished_ns)
      from = meta[:started_at_unix_ns] / 1_000_000_000
      untl = (finished_ns / 1_000_000_000.0).ceil
      untl = from + 1 if untl <= from
      uri = URI("#{ENV.fetch("BENCH_PYROSCOPE_URL", "http://lgtm:4040")}/ingest")
      uri.query = URI.encode_www_form(
        # sampleRate must match the wall interval so Pyroscope's seconds axis
        # is real time, not a samples count.
        name: "lobsters.wall{path=#{meta[:path]},method=#{meta[:method]},trace_id=#{meta[:trace_id]}}",
        from: from, until: untl, sampleRate: 1_000_000 / meta[:interval_us],
        format: "folded", units: "samples"
      )
      res = Net::HTTP.post(uri, folded, "Content-Type" => "text/plain")
      unless res.is_a?(Net::HTTPSuccess)
        Rails.logger.warn "profile_probe: pyroscope ingest returned #{res.code} #{res.body.to_s[0, 200]}"
      end
    rescue => e
      Rails.logger.warn "profile_probe: pyroscope push failed (#{e.class}: #{e.message})"
    end

    class << self
      def install!
        return if ENV["BENCH_PROFILE_PATH"].to_s.empty?
        require "stackprof" # scoped here so install_optional catches a missing gem
        require "net/http"
        # Same slot as RequestProbe: inside the root span (so the meta file can
        # record the trace id) but above the whole app stack.
        Rails.application.config.middleware.insert_after Rack::Events, ProfileProbe
      end
    end
  end
end
