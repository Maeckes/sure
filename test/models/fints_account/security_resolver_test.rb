# frozen_string_literal: true

require_relative "../../support/fints_test_helper"

class FintsAccount::SecurityResolverTest < ActiveSupport::TestCase
  include FintsTestHelper

  setup do
    item = FintsItem.create!(
      family: families(:dylan_family), name: "Dummy", bank_name: "Dummy",
      bank_code: "50010517", endpoint: "https://bank.example/fints",
      user_id: "dummy-user", pin: "dummy-pin"
    )
    @account = item.fints_accounts.create!(
      remote_account_key: "a" * 64, name: "Depot", currency: "EUR", holdings_supported: true
    )
    @resolver = FintsAccount::SecurityResolver.new(@account)
  end

  test "reuses an ISIN security when its name changes" do
    first = @resolver.resolve(isin: "DE000DUMMY01", name: "Old fund name")
    second = @resolver.resolve(isin: "de000dummy01", name: "New fund name")

    assert_equal first, second
    assert_equal "DE000DUMMY01", first.ticker
    assert_equal 1, Security.where(ticker: "DE000DUMMY01").count
  end

  test "keeps similar ISIN-less holdings distinct" do
    first = @resolver.resolve(isin: nil, name: "Dummy Growth Fund A")
    second = @resolver.resolve(isin: nil, name: "Dummy Growth Fund B")

    assert_not_equal first, second
    assert_match(/\AFINTS:[0-9A-F]{24}\z/, first.ticker)
    assert first.offline?
  end

  test "scopes an ISIN-less fallback identity to the remote account" do
    sibling = @account.fints_item.fints_accounts.create!(
      remote_account_key: "b" * 64, name: "Second depot", currency: "EUR", holdings_supported: true
    )

    first = @resolver.resolve(isin: nil, name: "Same fund")
    second = FintsAccount::SecurityResolver.new(sibling).resolve(isin: nil, name: "Same fund")

    assert_not_equal first, second
  end

  test "rejects a holding with neither ISIN nor name" do
    assert_raises(ArgumentError) { @resolver.resolve(isin: nil, name: nil) }
  end
end
