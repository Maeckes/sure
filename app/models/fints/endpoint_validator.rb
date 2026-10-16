# frozen_string_literal: true

require "ipaddr"
require "uri"

class Fints::EndpointValidator
  InvalidEndpoint = Class.new(StandardError)

  PRIVATE_NETWORKS = %w[0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8].map { IPAddr.new(_1) }.freeze

  def self.validate!(value)
    uri = URI.parse(value.to_s)
    raise InvalidEndpoint, "must be an HTTPS URL" unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && uri.fragment.nil?

    address = IPAddr.new(uri.host)
    raise InvalidEndpoint, "must not target a private network" if PRIVATE_NETWORKS.any? { _1.include?(address) }

    true
  rescue URI::InvalidURIError, IPAddr::InvalidAddressError
    true if uri&.is_a?(URI::HTTPS) && uri.host.present?
  end
end
