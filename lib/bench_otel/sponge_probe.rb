# frozen_string_literal: true

module BenchOtel
  # Spans for Sponge (extras/sponge.rb), the hand-rolled outbound HTTP client
  # behind Story#fetched_attributes and friends. Gemfile.bench only carries the
  # Rails-family instrumentation, so use_all covers neither Net::HTTP nor
  # Resolv -- and Sponge resolves DNS itself (SSRF guard) before Net::HTTP is
  # ever touched, so the net_http instrumentation gem would miss that phase
  # anyway. Without this, an outbound fetch is pure unattributed self time on
  # process_action.
  #
  # Sponge follows redirects by recursing into #fetch, so a redirect chain
  # shows up as nested sponge.fetch spans, each with its own dns.resolve child.
  # DNS failures, SSRF rejections and redirect exhaustion raise out of #fetch;
  # in_span records the exception and marks the span as error. An HTTP timeout
  # returns nil, which surfaces as a span with no http.response.status_code.
  module SpongeProbe
    module FetchProbe
      def fetch(url, method = :get, fields = {}, raw_post_data = nil, headers = {}, limit = 10)
        BenchOtel.tracer.in_span("sponge.fetch", attributes: {
          "url.full" => url.to_s,
          "http.request.method" => method.to_s.upcase,
          "sponge.redirects_left" => limit
        }) do |span|
          res = super
          span.set_attribute("http.response.status_code", res.code.to_i) if res.respond_to?(:code)
          res
        end
      end
    end

    module ResolvProbe
      def getaddresses(host)
        BenchOtel.tracer.in_span("dns.resolve", attributes: {"server.address" => host.to_s}) do |span|
          super.tap { |ips| span.set_attribute("dns.address_count", ips.length) }
        end
      end
    end

    class << self
      def install!
        # Sponge lives in extras/, which is autoloaded: referencing it during
        # initialization would trip Zeitwerk, and in development a reload would
        # discard the prepend. to_prepare runs after boot and again on every
        # reload, re-applying to the fresh class.
        Rails.application.config.to_prepare do
          Sponge.prepend(FetchProbe) unless Sponge.include?(FetchProbe)
          Resolv.singleton_class.prepend(ResolvProbe) unless Resolv.singleton_class.include?(ResolvProbe)
        end
      end
    end
  end
end
