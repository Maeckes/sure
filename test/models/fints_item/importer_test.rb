# frozen_string_literal: true

require_relative "../../support/fints_test_helper"

class FintsItem::ImporterTest < ActiveSupport::TestCase
  include FintsTestHelper

  class FakeWorker
    attr_reader :calls

    def initialize(results)
      @results = results
      @calls = []
    end

    def call(**request)
      @calls << request
      @results.shift
    end
  end

  setup do
    @family = families(:dylan_family)
    @item = FintsItem.create!(
      family: @family, name: "Dummy bank", bank_name: "Dummy bank",
      bank_code: "50010517", endpoint: "https://bank.example/fints",
      user_id: "dummy-user", customer_id: "dummy-customer", pin: "dummy-pin"
    )
  end

  test "discovers ING checking and extra accounts without creating Sure accounts" do
    worker = FakeWorker.new([ success(accounts: [ account("Girokonto", "checking", "a"), account("Extra-Konto", "savings", "b", balance: nil) ]) ])

    assert_no_difference "Account.count" do
      @item.discover_accounts!(worker: worker)
    end

    assert_equal 2, @item.fints_accounts.count
    assert_equal "checking", @item.fints_accounts.find_by!(name: "Girokonto").suggested_subtype
    extra = @item.fints_accounts.find_by!(name: "Extra-Konto")
    assert_equal "savings", extra.suggested_subtype
    assert_not extra.balance_available?
    assert_match(/•••• 0001/, extra.iban_mask)
  end

  test "discovers a generic Sparkasse savings account" do
    worker = FakeWorker.new([ success(accounts: [ account("Sparkonto", "Sparen", "c") ]) ])
    @item.discover_accounts!(worker: worker)
    assert_equal "savings", @item.fints_accounts.sole.suggested_subtype
  end

  test "explicit mapping can create or reuse a depository account" do
    worker = FakeWorker.new([ success(accounts: [ account("Girokonto", "checking", "d") ]) ])
    @item.discover_accounts!(worker: worker)
    remote = @item.fints_accounts.sole

    created = remote.create_and_link_account!
    assert_equal created, remote.reload.account
    assert_equal "Depository", created.accountable_type

    second = @item.fints_accounts.create!(remote_account_key: "e" * 64, name: "Savings", currency: "EUR")
    existing = @family.accounts.create!(accountable: Depository.create!(subtype: "savings"), name: "Existing", currency: "EUR", balance: 0)
    second.link_to_existing!(existing)
    assert_equal existing, second.reload.account
  end

  test "mapping refuses an account already owned by another provider" do
    remote = @item.fints_accounts.create!(remote_account_key: "3" * 64, name: "Savings", currency: "EUR")
    existing = accounts(:depository)
    AccountProvider.create!(account: existing, provider: fio_accounts(:checking))

    assert_raises(ArgumentError) { remote.link_to_existing!(existing) }
    assert_nil remote.reload.account_provider
  end

  test "uses 90 days initially and seven day overlap after a completed sync" do
    remote = linked_remote("f")
    first_worker = FakeWorker.new([ success(accounts: [ transaction_account(remote, start_date: (Date.current - 90.days).iso8601) ]) ])
    @item.import_latest_fints_data(worker: first_worker)
    assert_equal (Date.current - 90.days).iso8601, first_worker.calls.first[:accountWindows].sole[:startDate]

    second_worker = FakeWorker.new([ success(accounts: [ transaction_account(remote, start_date: (Date.current - 7.days).iso8601) ]) ])
    @item.import_latest_fints_data(worker: second_worker)
    assert_equal (Date.current - 7.days).iso8601, second_worker.calls.first[:accountWindows].sole[:startDate]
  end

  test "isolates account processing failure" do
    good = linked_remote("1")
    bad = linked_remote("2")
    FintsAccount::Processor.any_instance.stubs(:process).raises(StandardError)
    result = @item.import_latest_fints_data(worker: FakeWorker.new([ success(accounts: [ transaction_account(good), transaction_account(bad) ]) ]))
    assert_not result[:success]
    assert_equal 2, result[:accounts].size
  end

  test "sensitive attributes are encrypted at rest" do
    raw = FintsItem.connection.select_one("SELECT user_id, customer_id, pin FROM fints_items WHERE id = '#{@item.id}'")
    assert_not_equal "dummy-user", raw["user_id"]
    assert_not_equal "dummy-customer", raw["customer_id"]
    assert_not_equal "dummy-pin", raw["pin"]
  end

  private

    def account(name, type, key, balance: 12_345)
      {
        "remoteAccountKey" => key * 64, "name" => name, "accountType" => type,
        "currency" => "EUR", "iban" => "DE44500105175407320001", "accountNumber" => "0001",
        "supportsTransactions" => true, "balance" => balance, "transactions" => [],
        "transactionSync" => { "status" => "not_requested", "startDate" => nil, "endDate" => nil }
      }
    end

    def success(accounts:)
      Fints::WorkerClient::Success.new("opaque-state", nil, nil, accounts)
    end

    def linked_remote(key)
      remote = @item.fints_accounts.create!(remote_account_key: key * 64, name: "Account #{key}", currency: "EUR", transactions_supported: true)
      remote.create_and_link_account!
      remote
    end

    def transaction_account(remote, start_date: (Date.current - 90.days).iso8601)
      account(remote.name, "checking", remote.remote_account_key.first).merge(
        "remoteAccountKey" => remote.remote_account_key,
        "transactionSync" => { "status" => "completed", "startDate" => start_date, "endDate" => Date.current.iso8601 }
      )
    end
end
