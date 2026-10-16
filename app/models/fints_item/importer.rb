# frozen_string_literal: true

require "digest"

class FintsItem::Importer
  attr_reader :fints_item, :worker

  def initialize(fints_item, worker:)
    @fints_item = fints_item
    @worker = worker
  end

  def discover
    result = worker.call(operation: :discover, credentials: credentials)
    return result unless result.is_a?(Fints::WorkerClient::Success)

    persist_session!(result)
    result.accounts.each { upsert_account!(_1) }
    fints_item.update!(pending_account_setup: fints_item.fints_accounts.needs_setup.exists?)
    result
  end

  def import
    linked = fints_item.fints_accounts.joins(:account_provider).to_a
    return { success: true, accounts: [] } if linked.empty?

    windows = linked.map do |account|
      from = if account.transactions_synced_through
        account.transactions_synced_through - Rails.configuration.x.fints.sync_lookback_days.days
      else
        Date.current - Rails.configuration.x.fints.initial_history_days.days
      end
      { remoteAccountKey: account.remote_account_key, startDate: from.iso8601, endDate: Date.current.iso8601 }
    end

    result = worker.call(operation: :transactions, credentials: credentials, accountWindows: windows)
    return result unless result.is_a?(Fints::WorkerClient::Success)

    persist_session!(result)
    outcomes = result.accounts.filter_map do |snapshot|
      account = fints_item.fints_accounts.find_by(remote_account_key: snapshot["remoteAccountKey"])
      next unless account&.account_provider

      process_account(account, snapshot)
    end
    { success: outcomes.all? { _1[:success] }, accounts: outcomes }
  end

  private

    def credentials
      {
        bank_code: fints_item.bank_code, endpoint: fints_item.endpoint,
        user_id: fints_item.user_id, customer_id: fints_item.customer_id,
        pin: fints_item.pin, client_state: fints_item.client_state,
        tan_mechanism: fints_item.tan_mechanism, tan_medium: fints_item.tan_medium
      }
    end

    def persist_session!(result)
      fints_item.update!(
        client_state: result.client_state,
        tan_mechanism: result.tan_mechanism,
        tan_medium: result.tan_medium,
        status: :good
      )
    end

    def upsert_account!(snapshot)
      account = fints_item.fints_accounts.find_or_initialize_by(remote_account_key: snapshot.fetch("remoteAccountKey"))
      account.assign_attributes(
        name: snapshot.fetch("name").to_s.truncate(255),
        remote_account_type: snapshot["accountType"],
        currency: snapshot.fetch("currency"),
        iban_mask: mask_identifier(snapshot["iban"] || snapshot["accountNumber"]),
        account_fingerprint: fingerprint(snapshot["iban"] || snapshot["accountNumber"]),
        current_balance: cents_to_decimal(snapshot["balance"]),
        balance_available: !snapshot["balance"].nil?,
        transactions_supported: snapshot["supportsTransactions"] != false
      )
      account.save!
      account
    end

    def process_account(account, snapshot)
      balance_attributes = { balance_available: !snapshot["balance"].nil? }
      balance_attributes[:current_balance] = cents_to_decimal(snapshot["balance"]) unless snapshot["balance"].nil?
      account.update!(balance_attributes)

      processor = FintsAccount::Processor.new(account)
      outcome = processor.process(snapshot.fetch("transactions"))
      diagnostic = snapshot["transactionSync"] || {}
      if diagnostic["status"] == "completed"
        account.update!(
          transactions_synced_through: Date.iso8601(diagnostic.fetch("endDate")),
          history_synced_from: [ account.history_synced_from, Date.iso8601(diagnostic.fetch("startDate")) ].compact.min
        )
      end
      { fints_account_id: account.id, success: true, result: outcome }
    rescue StandardError => error
      DebugLogEntry.capture(
        category: "provider_sync_error", level: "error", message: "FinTS account import failed",
        source: self.class.name, provider_key: "fints", family: fints_item.family,
        account_provider: account.account_provider,
        metadata: { fints_item_id: fints_item.id, fints_account_id: account.id, error_class: error.class.name }
      )
      { fints_account_id: account.id, success: false }
    end

    def cents_to_decimal(value)
      value.nil? ? nil : BigDecimal(value.to_s) / 100
    end

    def fingerprint(value)
      normalized = value.to_s.gsub(/\s+/, "").upcase
      normalized.present? ? Digest::SHA256.hexdigest("fints-account-identity:v1:#{fints_item.bank_code}:#{normalized}") : nil
    end

    def mask_identifier(value)
      value.present? ? "•••• #{value.to_s.gsub(/\s+/, "").last(4)}" : nil
    end
end
