# frozen_string_literal: true

require_relative "../../support/fints_test_helper"

class FintsAccount::HoldingsProcessorTest < ActiveSupport::TestCase
  include FintsTestHelper

  setup do
    item = FintsItem.create!(
      family: families(:dylan_family), name: "Dummy", bank_name: "Dummy",
      bank_code: "50010517", endpoint: "https://bank.example/fints",
      user_id: "dummy-user", pin: "dummy-pin"
    )
    @remote = item.fints_accounts.create!(
      remote_account_key: "d" * 64, name: "Direkt-Depot", currency: "EUR",
      holdings_supported: true, transactions_supported: false
    )
    @account = @remote.create_and_link_account!
    @processor = FintsAccount::HoldingsProcessor.new(@remote)
  end

  test "imports exact decimal strings and trusts the bank total value" do
    result = nil
    assert_no_difference "Trade.count" do
      result = @processor.process([ holding(
        quantity: "12.34567890123456789",
        unit_price: "101.23456789",
        total_value: "1249.81",
        acquisition_price: "87.654321"
      ) ])
    end

    imported = @account.holdings.sole
    assert_equal BigDecimal("12.34567890123456789"), imported.qty
    assert_equal BigDecimal("101.2346"), imported.price
    assert_equal BigDecimal("1249.81"), imported.amount
    assert_equal "EUR", imported.currency
    assert_equal Date.current, imported.date
    assert_equal BigDecimal("1249.81"), @account.reload.balance
    assert_nil imported.cost_basis
    assert_nil imported.cost_basis_source
    assert_equal Date.current, result.snapshot_date
  end

  test "does not accept float input in the Rails import path" do
    payload = holding
    payload["quantity"] = 12.5

    assert_raises(ArgumentError) { @processor.process([ payload ]) }
    assert_empty @account.holdings
  end

  test "repeated same-day snapshots update one holding" do
    @processor.process([ holding(quantity: "10") ])

    assert_no_difference "Holding.count" do
      @processor.process([ holding(quantity: "12", total_value: "1214.81481468") ])
    end

    imported = @account.holdings.sole
    assert_equal BigDecimal("12"), imported.qty
    assert_equal BigDecimal("1214.8148"), imported.amount
  end

  test "an older snapshot cannot replace the current account value" do
    @processor.process([ holding(date: Date.current, total_value: "1200") ])
    @processor.process([ holding(date: Date.current - 1, total_value: "900") ])

    assert_equal BigDecimal("1200"), @account.reload.balance
    assert_equal Date.current, @account.latest_provider_holdings_snapshot_date
  end

  test "a complete later snapshot closes a missing position without deleting history" do
    @processor.process([
      holding(isin: "DE000DUMMY01", name: "Fund A", date: Date.current - 1),
      holding(isin: "DE000DUMMY02", name: "Fund B", date: Date.current - 1)
    ])

    @processor.process([
      holding(isin: "DE000DUMMY02", name: "Fund B", date: Date.current, quantity: "5", total_value: "506.17283945")
    ])

    assert_equal 2, @account.holdings.where(date: Date.current - 1).count
    closed = @account.holdings.joins(:security).find_by!(date: Date.current, securities: { ticker: "DE000DUMMY01" })
    assert_equal 0, closed.qty
    assert_equal [ "DE000DUMMY02" ], @account.current_holdings.joins(:security).pluck("securities.ticker")
  end

  test "an empty snapshot without a valuation date preserves the last known positions" do
    @processor.process([ holding(date: Date.current - 1) ])

    assert_no_difference "Holding.count" do
      result = @processor.process([])
      assert_nil result.snapshot_date
    end

    assert_equal 1, @account.current_holdings.count
  end

  test "uses provider ISIN identity and supports a holding without ISIN" do
    @processor.process([
      holding,
      holding(isin: nil, name: "Unlisted employee fund", total_value: "50", quantity: "1", unit_price: "50")
    ])

    assert_equal 2, @account.holdings.count
    assert @account.holdings.joins(:security).exists?(securities: { ticker: "DE000DUMMY01" })
    assert @account.holdings.joins(:security).where("securities.ticker LIKE 'FINTS:%'").exists?
  end

  private

    def holding(isin: "DE000DUMMY01", name: "Dummy fund", quantity: "10", unit_price: "101.23456789", total_value: "1012.3456789", acquisition_price: nil, date: Date.current)
      {
        "isin" => isin, "name" => name, "quantity" => quantity,
        "unitPrice" => unit_price, "currency" => "EUR",
        "valuationDate" => date.iso8601, "totalValue" => total_value,
        "acquisitionPrice" => acquisition_price
      }
    end
end
