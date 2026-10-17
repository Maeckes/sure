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

  test "discovers an UPD-only depot without creating or mapping it" do
    snapshot = account("Direkt-Depot", "Depot", "d", balance: nil).merge(
      "iban" => nil, "accountNumber" => "7654321",
      "supportsTransactions" => false, "supportsHoldings" => true
    )
    worker = FakeWorker.new([ success(accounts: [ snapshot ]) ])

    assert_no_difference [ "Account.count", "AccountProvider.count" ] do
      @item.discover_accounts!(worker: worker)
    end

    depot = @item.fints_accounts.sole
    assert depot.holdings_supported?
    assert depot.investment?
    assert_equal "Investment", depot.suggested_accountable_type
    assert_equal "brokerage", depot.suggested_subtype
    assert_equal "•••• 4321", depot.iban_mask
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

  test "continues discovery and persists returned client state" do
    worker = FakeWorker.new([ success(accounts: [ account("Girokonto", "checking", "a") ]) ])

    result = FintsItem::Importer.new(@item, worker: worker).continue(
      operation: "discover",
      worker_state: "paused-state",
      tan: "123456"
    )

    assert_instance_of Fints::WorkerClient::Success, result
    assert_equal "opaque-state", @item.reload.client_state
    assert_equal 1, @item.fints_accounts.count
    assert_equal({ operation: :continue, credentials: {
      bank_code: "50010517", endpoint: "https://bank.example/fints",
      user_id: "dummy-user", customer_id: "dummy-customer", pin: "dummy-pin",
      client_state: nil, tan_mechanism: nil, tan_medium: nil
    }, continuation: { operation: "discover", workerState: "paused-state", tan: "123456" } }, worker.calls.sole)
  end

  test "continues transaction import through the existing processor" do
    remote = linked_remote("f")
    snapshot = transaction_account(remote)
    FintsAccount::Processor.any_instance.expects(:process).with(snapshot["transactions"]).returns(imported: 1)
    worker = FakeWorker.new([ success(accounts: [ snapshot ]) ])

    result = FintsItem::Importer.new(@item, worker: worker).continue(
      operation: "transactions",
      worker_state: "paused-state",
      tan: nil
    )

    assert result[:success]
    assert_equal Date.current, remote.reload.transactions_synced_through
  end

  test "sync requests cash transactions and investment holdings together" do
    cash = linked_remote("f")
    depot = linked_depot("d")
    worker = FakeWorker.new([ success(accounts: [ transaction_account(cash), holdings_account(depot) ]) ])

    result = @item.import_latest_fints_data(worker: worker)

    request = worker.calls.sole
    assert_equal :sync, request[:operation]
    assert_equal [ cash.remote_account_key ], request[:accountWindows].pluck(:remoteAccountKey)
    assert_equal [ depot.remote_account_key ], request[:remoteAccountKeys]
    assert result[:success]
    assert_equal "completed", depot.reload.holdings_status
    assert_equal 1, depot.account.holdings.where.not(qty: 0).count
  end

  test "unsupported depot holdings do not block cash or another depot" do
    cash = linked_remote("1")
    unsupported = linked_depot("2")
    working = linked_depot("3")
    unsupported_snapshot = holdings_account(unsupported).merge(
      "holdings" => [],
      "holdingsSync" => holdings_sync("unsupported", received: 0, normalized: 0)
    )
    worker = FakeWorker.new([ success(accounts: [
      transaction_account(cash), unsupported_snapshot, holdings_account(working)
    ]) ])

    result = @item.import_latest_fints_data(worker: worker)

    assert result[:success]
    assert_equal Date.current, cash.reload.transactions_synced_through
    assert_equal "unsupported", unsupported.reload.holdings_status
    assert_equal "completed", working.reload.holdings_status
    assert_equal 1, working.account.holdings.where.not(qty: 0).count
  end

  test "a malformed depot snapshot does not block another depot" do
    malformed = linked_depot("2")
    working = linked_depot("3")
    malformed_snapshot = holdings_account(malformed)
    malformed_snapshot["holdings"].first["quantity"] = "not-a-decimal"
    worker = FakeWorker.new([ success(accounts: [ malformed_snapshot, holdings_account(working) ]) ])

    result = @item.import_latest_fints_data(worker: worker)

    assert_not result[:success]
    assert_equal "unavailable", malformed.reload.holdings_status
    assert_equal "completed", working.reload.holdings_status
    assert_equal 1, working.account.holdings.where.not(qty: 0).count
  end

  test "continues a combined holdings sync through the existing challenge path" do
    depot = linked_depot("d")
    worker = FakeWorker.new([ success(accounts: [ holdings_account(depot) ]) ])

    result = FintsItem::Importer.new(@item, worker: worker).continue(
      operation: "sync", worker_state: "paused-state", tan: "123456"
    )

    assert result[:success]
    assert_equal "completed", depot.reload.holdings_status
    assert_equal "sync", worker.calls.sole.dig(:continuation, :operation)
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
        "supportsTransactions" => true, "supportsHoldings" => false,
        "balance" => balance, "transactions" => [], "holdings" => [],
        "transactionSync" => { "status" => "not_requested", "startDate" => nil, "endDate" => nil },
        "holdingsSync" => holdings_sync("not_requested", received: 0, normalized: 0)
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

    def linked_depot(key)
      remote = @item.fints_accounts.create!(
        remote_account_key: key * 64, name: "Depot #{key}", currency: "EUR",
        transactions_supported: false, holdings_supported: true
      )
      remote.create_and_link_account!
      remote
    end

    def transaction_account(remote, start_date: (Date.current - 90.days).iso8601)
      account(remote.name, "checking", remote.remote_account_key.first).merge(
        "remoteAccountKey" => remote.remote_account_key,
        "transactionSync" => { "status" => "completed", "startDate" => start_date, "endDate" => Date.current.iso8601 }
      )
    end

    def holdings_account(remote)
      account(remote.name, "Depot", remote.remote_account_key.first, balance: nil).merge(
        "remoteAccountKey" => remote.remote_account_key,
        "supportsTransactions" => false,
        "supportsHoldings" => true,
        "holdings" => [ {
          "isin" => "DE000DUMMY01", "name" => "Dummy Equity Fund",
          "quantity" => "12.34567890123456789", "unitPrice" => "101.23456789",
          "currency" => "EUR", "valuationDate" => Date.current.iso8601,
          "totalValue" => "1249.81", "acquisitionPrice" => "87.654321"
        } ],
        "holdingsSync" => holdings_sync("completed", received: 1, normalized: 1)
      )
    end

    def holdings_sync(status, received:, normalized:)
      { "status" => status, "received" => received, "normalized" => normalized, "discarded" => received - normalized }
    end
end
