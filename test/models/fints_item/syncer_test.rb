# frozen_string_literal: true

require_relative "../../support/fints_test_helper"

class FintsItem::SyncerTest < ActiveSupport::TestCase
  include FintsTestHelper

  setup do
    @item = FintsItem.create!(
      family: families(:dylan_family), name: "Dummy", bank_name: "Dummy bank",
      bank_code: "50010517", endpoint: "https://bank.example/fints",
      user_id: "dummy-user", pin: "dummy-pin"
    )
    remote = @item.fints_accounts.create!(
      remote_account_key: "d" * 64, name: "Depot", currency: "EUR",
      holdings_supported: true, transactions_supported: false
    )
    @account = remote.create_and_link_account!
  end

  test "schedules linked account materialization as a child of the provider sync" do
    sync = @item.syncs.create!(
      window_start_date: Date.current - 30,
      window_end_date: Date.current
    )
    @item.stubs(:import_latest_fints_data).returns(success: true, accounts: [])
    Account.any_instance.expects(:sync_later).with(
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )

    FintsItem::Syncer.new(@item).perform_sync(sync)
  end

  test "does not schedule account materialization while bank confirmation is pending" do
    challenge = Fints::WorkerClient::Challenge.new("decoupled", "Approve", nil, nil, "private-state")
    @item.stubs(:import_latest_fints_data).returns(challenge)
    Account.any_instance.expects(:sync_later).never

    FintsItem::Syncer.new(@item).perform_sync(@item.syncs.create!)
  end
end
