# frozen_string_literal: true

require "digest"

class FintsAccount::HoldingsProcessor
  Result = Data.define(:received, :imported, :snapshot_date, :total_value)

  def initialize(fints_account, security_resolver: FintsAccount::SecurityResolver.new(fints_account), observed_on: Date.current)
    @fints_account = fints_account
    @security_resolver = security_resolver
    @observed_on = observed_on
  end

  def process(raw_holdings)
    raise Fints::HoldingsImportError.new(:non_investment_account) unless account&.investment?

    positions = Array(raw_holdings).map { normalize(_1) }
    snapshot_date = positions.filter_map { _1[:date] }.max
    # python-fints only exposes MT535 :98A::PRIC dates attached to individual
    # positions. Some banks omit those dates for a complete current snapshot.
    # In that case the retrieval date is the only trustworthy observation date.
    snapshot_date ||= observed_on if positions.any?
    positions.each { _1[:date] ||= snapshot_date }
    previous_snapshot_date = account.latest_provider_holdings_snapshot_date
    previous_holdings = account.current_holdings.where(account_provider_id: account_provider.id).to_a
    imported = []

    Account.transaction do
      positions.each do |position|
        imported << with_argument_code(:holding_persistence_argument) { import_position(position) }
      end
      if snapshot_date && (previous_snapshot_date.nil? || snapshot_date >= previous_snapshot_date)
        with_argument_code(:missing_position_close_argument) do
          close_missing_positions!(previous_holdings, imported, snapshot_date)
        end
        with_argument_code(:balance_update_argument) do
          update_investment_balance!(imported, snapshot_date)
        end
      end
    end

    Result.new(positions.size, imported.size, snapshot_date, imported.sum(BigDecimal("0"), &:amount))
  end

  private

    attr_reader :fints_account, :security_resolver, :observed_on

    def account
      fints_account.account
    end

    def account_provider
      fints_account.account_provider
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def normalize(raw)
      value = raw.with_indifferent_access
      quantity = decimal!(value[:quantity], field: "quantity")
      price = decimal(value[:unitPrice])
      amount = decimal(value[:totalValue])
      date = parse_date(value[:valuationDate])
      raise Fints::HoldingsImportError.new(:missing_price_and_value) if price.nil? && amount.nil?

      price ||= quantity.zero? ? BigDecimal("0") : amount / quantity
      amount ||= quantity * price
      if quantity.negative? || price.negative? || amount.negative?
        raise Fints::HoldingsImportError.new(:negative_value)
      end

      currency = value[:currency].to_s.upcase
      currency = fints_account.currency if currency.blank?
      unless currency.match?(/\A[A-Z]{3}\z/)
        raise Fints::HoldingsImportError.new(:invalid_currency)
      end

      {
        isin: value[:isin], name: value[:name].to_s.squish.presence,
        quantity: quantity, price: price, amount: amount,
        currency: currency, date: date
      }
    end

    def import_position(position)
      security = security_resolver.resolve(isin: position[:isin], name: position[:name])
      import_adapter.import_holding(
        security: security,
        quantity: position[:quantity],
        amount: position[:amount],
        currency: position[:currency],
        date: position[:date],
        price: position[:price],
        external_id: external_id(security, position[:date]),
        source: "fints",
        account_provider_id: account_provider.id,
        delete_future_holdings: false
      )
    end

    def close_missing_positions!(previous_holdings, imported, snapshot_date)
      current_provider_security_ids = imported.map { _1.provider_security_id || _1.security_id }.to_set
      previous_holdings.each do |holding|
        provider_security = holding.provider_security || holding.security
        next if current_provider_security_ids.include?(provider_security.id)

        import_adapter.import_holding(
          security: provider_security,
          quantity: BigDecimal("0"), amount: BigDecimal("0"),
          currency: holding.currency, date: snapshot_date, price: holding.price,
          external_id: external_id(provider_security, snapshot_date),
          source: "fints", account_provider_id: account_provider.id,
          delete_future_holdings: false
        )
      end
    end

    def update_investment_balance!(imported, snapshot_date)
      total = imported.sum(BigDecimal("0")) do |holding|
        if holding.currency == account.currency
          holding.amount
        else
          Money.new(holding.amount, holding.currency).exchange_to(account.currency, date: snapshot_date).amount
        end
      end
      account.update!(balance: total, cash_balance: 0, currency: fints_account.currency)
      result = account.set_current_balance(total, date: snapshot_date, schedule_sync: false)
      raise "Could not set FinTS investment balance" unless result.success?
    end

    def external_id(security, date)
      identity = "#{fints_account.remote_account_key}:#{security.ticker}:#{date.iso8601}"
      "fints_holding_#{Digest::SHA256.hexdigest(identity)}"
    end

    def decimal(value)
      return nil if value.nil?
      unless value.is_a?(String) || value.is_a?(BigDecimal)
        raise Fints::HoldingsImportError.new(:invalid_decimal)
      end

      BigDecimal(value.to_s)
    rescue ArgumentError => error
      raise if error.is_a?(Fints::HoldingsImportError)

      raise Fints::HoldingsImportError.new(:invalid_decimal)
    end

    def decimal!(value, field:)
      decimal(value) || raise(Fints::HoldingsImportError.new("missing_#{field}"))
    end

    def parse_date(value)
      return value if value.is_a?(Date)
      return nil unless value.is_a?(String)

      Date.iso8601(value)
    rescue Date::Error
      nil
    end

    def with_argument_code(code)
      yield
    rescue Fints::HoldingsImportError
      raise
    rescue ArgumentError
      raise Fints::HoldingsImportError.new(code)
    end
end
