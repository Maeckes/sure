# frozen_string_literal: true

require "digest"

class FintsAccount::SecurityResolver
  ISIN_PATTERN = /\A[A-Z]{2}[A-Z0-9]{9}\d\z/
  OFFLINE_REASON = "fints_holding"

  def initialize(fints_account)
    @fints_account = fints_account
  end

  def resolve(isin:, name:)
    normalized_isin = isin.to_s.strip.upcase.presence
    if normalized_isin
      unless normalized_isin.match?(ISIN_PATTERN)
        raise Fints::HoldingsImportError.new(:invalid_security_identity)
      end

      find_or_create!(ticker: normalized_isin, name: name.presence || normalized_isin)
    else
      normalized_name = name.to_s.squish
      raise Fints::HoldingsImportError.new(:missing_security_identity) if normalized_name.blank?

      digest = Digest::SHA256.hexdigest(
        "fints-security:v1:#{@fints_account.remote_account_key}:#{normalized_name.downcase}"
      )
      find_or_create!(ticker: "FINTS:#{digest.first(24)}", name: normalized_name)
    end
  end

  private

    def find_or_create!(ticker:, name:)
      Security.find_by(ticker: ticker) || Security.create!(
        ticker: ticker,
        name: name,
        offline: true,
        offline_reason: OFFLINE_REASON
      )
    rescue ActiveRecord::RecordNotUnique
      Security.find_by!(ticker: ticker)
    end
end
