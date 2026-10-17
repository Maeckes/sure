# frozen_string_literal: true

require_relative "../support/fints_test_helper"

class FintsItemsControllerTest < ActionDispatch::IntegrationTest
  include FintsTestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @item = FintsItem.create!(family: @family, name: "Dummy", bank_name: "Dummy", bank_code: "50010517", endpoint: "https://bank.example/fints", user_id: "dummy-user", pin: "dummy-pin")
    @remote = @item.fints_accounts.create!(remote_account_key: "a" * 64, name: "Extra-Konto", remote_account_type: "savings", currency: "EUR", iban_mask: "•••• 1234")
  end

  test "lists only masked discovered accounts" do
    get accounts_fints_item_url(@item)
    assert_response :success
    assert_equal "•••• 1234", response.parsed_body.dig("accounts", 0, "identifier")
    assert_not_includes response.body, "dummy-user"
    assert_not_includes response.body, "dummy-pin"
  end

  test "mapping explicitly creates a local depository account" do
    assert_difference "Account.count", 1 do
      post map_account_fints_item_url(@item), params: { fints_account_id: @remote.id, subtype: "savings" }
    end
    assert_response :created
    assert_equal "savings", @remote.reload.account.subtype
  end

  test "mapping can use an existing local depository account" do
    existing = @family.accounts.create!(accountable: Depository.create!(subtype: "checking"), name: "Existing", currency: "EUR", balance: 0)
    assert_no_difference "Account.count" do
      post map_account_fints_item_url(@item), params: { fints_account_id: @remote.id, account_id: existing.id }
    end
    assert_response :created
    assert_equal existing, @remote.reload.account
  end

  test "challenge response persists encrypted state without exposing it" do
    FintsItem.any_instance.expects(:discover_accounts!).returns(Fints::WorkerClient::Challenge.new("tan", "Confirm with bank", nil, nil, "private-state"))

    post discover_fints_item_url(@item), as: :json
    assert_response :conflict
    assert_equal "challenge_required", response.parsed_body["status"]
    assert_match(/\A[A-Za-z0-9_-]{40,100}\z/, response.parsed_body["challenge_id"])
    assert_not_includes response.body, "dummy-user"
    assert_not_includes response.body, "dummy-pin"
    assert_not_includes response.body, "private-state"
    assert_equal 1, FintsChallenge.count
  end

  test "manual transaction sync surfaces a challenge without enqueueing a job" do
    FintsItem.any_instance.expects(:import_latest_fints_data).returns(
      Fints::WorkerClient::Challenge.new("decoupled", "Approve in app", nil, nil, "private-state")
    )

    assert_no_enqueued_jobs do
      post sync_fints_item_url(@item), as: :json
    end

    assert_response :conflict
    assert_equal "decoupled", response.parsed_body["challenge_type"]
  end
end
