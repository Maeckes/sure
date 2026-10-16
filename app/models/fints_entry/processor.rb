# frozen_string_literal: true

require "digest"

class FintsEntry::Processor
  attr_reader :transaction, :fints_account

  def initialize(transaction, fints_account:)
    @transaction = transaction.with_indifferent_access
    @fints_account = fints_account
  end

  def process
    return unless fints_account.account && amount && booking_date

    Account::ProviderImportAdapter.new(fints_account.account).import_transaction(
      external_id: external_id,
      amount: amount,
      currency: transaction[:currency].presence || fints_account.currency,
      date: booking_date,
      name: transaction[:counterpartyName].presence || transaction[:purpose].presence || I18n.t("transactions.unknown_name"),
      source: "fints",
      notes: transaction[:purpose].presence,
      extra: safe_metadata,
      allow_heuristic_matching: false,
      replace_extra_namespaces: [ "fints" ]
    )
  end

  def external_id
    stable_references = {
      customer_reference: usable_reference(transaction[:customerReference]),
      bank_reference: usable_reference(transaction[:bankReference]),
      end_to_end_reference: usable_reference(transaction[:endToEndReference])
    }.compact
    canonical = {
      account: fints_account.remote_account_key,
      booking_date: transaction[:bookingDate], value_date: transaction[:valueDate],
      amount: transaction[:amount], currency: transaction[:currency],
      references: stable_references
    }
    canonical[:purpose] = transaction[:purpose] if stable_references.empty?
    canonical[:counterparty] = transaction[:counterpartyName] if stable_references.empty?
    "fints_#{Digest::SHA256.hexdigest(JSON.generate(canonical))}"
  end

  private

    def amount
      return @amount if defined?(@amount)
      @amount = -BigDecimal(transaction[:amount].to_s) / 100
    rescue ArgumentError, TypeError
      @amount = nil
    end

    def booking_date
      Date.iso8601(transaction[:bookingDate].to_s)
    rescue Date::Error
      nil
    end

    def safe_metadata
      {
        "fints" => {
          "value_date" => transaction[:valueDate],
          "transaction_code" => transaction[:transactionCode],
          "customer_reference" => transaction[:customerReference],
          "bank_reference" => transaction[:bankReference],
          "end_to_end_reference" => transaction[:endToEndReference],
          "mandate_reference" => transaction[:mandateReference],
          "creditor_id" => transaction[:creditorId]
        }.compact
      }
    end

    def usable_reference(value)
      reference = value.to_s.strip
      return if reference.blank? || reference.match?(/\A(?:NOTPROVIDED|NONREF|NOCUSTREF)\z/i)

      reference
    end
end
