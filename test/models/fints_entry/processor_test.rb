# frozen_string_literal: true

require "test_helper"

class FintsEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    item = FintsItem.create!(family: families(:dylan_family), name: "Dummy", bank_name: "Dummy", bank_code: "50010517", endpoint: "https://bank.example/fints", user_id: "dummy", pin: "dummy")
    @remote = item.fints_accounts.create!(remote_account_key: "9" * 64, name: "Giro", currency: "EUR")
    @account = @remote.create_and_link_account!
    @transaction = {
      "bookingDate" => "2026-10-01", "valueDate" => "2026-10-01", "amount" => -1234,
      "currency" => "EUR", "counterpartyName" => "Test Merchant", "purpose" => "Dummy purchase",
      "counterpartyIban" => "DE44500105175407324931", "customerReference" => "ref-1"
    }
  end

  test "imports with Sure sign convention and stable idempotent external id" do
    assert_difference "@account.entries.count", 1 do
      FintsEntry::Processor.new(@transaction, fints_account: @remote).process
    end
    assert_no_difference "@account.entries.count" do
      FintsEntry::Processor.new(@transaction, fints_account: @remote).process
    end

    entry = @account.entries.find_by!(source: "fints")
    assert_equal BigDecimal("12.34"), entry.amount
    assert_equal "Test Merchant", entry.name
  end

  test "does not persist full counterparty account identifiers" do
    FintsEntry::Processor.new(@transaction, fints_account: @remote).process
    serialized = @account.entries.find_by!(source: "fints").attributes.to_json
    serialized << @account.entries.find_by!(source: "fints").transaction.attributes.to_json
    assert_not_includes serialized, "DE44500105175407324931"
  end

  test "stable bank reference prevents duplicates when descriptive text changes" do
    original = @transaction.merge("bankReference" => "stable-bank-reference")
    changed = original.merge("purpose" => "Updated bank text", "counterpartyName" => "Updated name")

    assert_equal FintsEntry::Processor.new(original, fints_account: @remote).external_id,
      FintsEntry::Processor.new(changed, fints_account: @remote).external_id
  end
end
