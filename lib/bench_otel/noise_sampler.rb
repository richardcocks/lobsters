# frozen_string_literal: true

module BenchOtel
  # SolidQueue's supervisor (SOLID_QUEUE_IN_PUMA=1) polls its tables every
  # second or two from background threads. Each poll opens Model.transaction,
  # which opentelemetry-instrumentation-active_record has wrapped in an
  # 'ActiveRecord.transaction' span since 2023 -- the flood that appeared after
  # the 2026-07-21 recreate was not a gem change but the first boot where the
  # supervisor actually ran (podman restart keeps creation-time env, so the
  # SOLID_QUEUE_IN_PUMA added to compose later never took effect until the
  # container was recreated). With no request or job span above them, the
  # polls surfaced as ~40 root traces/min of one-span 'ActiveRecord.transaction'
  # / 'SolidQueue::*' noise.
  #
  # Dropping them here, at the sampler, discards the whole trace tree: children
  # inherit the root decision through parent_based. A span-processor filter
  # could not do this -- removing just the root would re-orphan its children
  # into exactly the noise being removed. Transaction spans *inside* requests
  # or jobs are untouched, because parent_based only consults the root sampler
  # when there is no parent.
  class NoiseSampler
    NOISE_ROOTS = [
      "ActiveRecord.transaction",
      /\ASolidQueue::/,
      # The subscribed instantiation.active_record event becomes its own root
      # when SolidQueue instantiates rows outside a transaction span. As a
      # root it can only ever be background noise; in requests and jobs it is
      # parented and therefore never consulted here.
      "instantiation.active_record"
    ].freeze

    def should_sample?(trace_id:, parent_context:, links:, name:, kind:, attributes:)
      decision = if NOISE_ROOTS.any? { |m| m === name }
        OpenTelemetry::SDK::Trace::Samplers::Decision::DROP
      else
        OpenTelemetry::SDK::Trace::Samplers::Decision::RECORD_AND_SAMPLE
      end
      OpenTelemetry::SDK::Trace::Samplers::Result.new(
        decision: decision,
        tracestate: OpenTelemetry::Trace.current_span(parent_context).context.tracestate
      )
    end

    def description = "BenchOtel::NoiseSampler{drop #{NOISE_ROOTS.map(&:to_s).join(", ")}}"
  end
end
