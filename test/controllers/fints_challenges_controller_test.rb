# frozen_string_literal: true

require_relative "../support/fints_test_helper"

class FintsChallengesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include FintsTestHelper

  setup do
    ensure_tailwind_build
    @user = users(:family_admin)
    sign_in @user
    @family = families(:dylan_family)
    @item = FintsItem.create!(
      family: @family,
      name: "Dummy",
      bank_name: "Dummy Bank",
      bank_code: "50010517",
      endpoint: "https://bank.example/fints",
      user_id: "dummy-user",
      pin: "dummy-pin"
    )
  end

  test "shows a text TAN challenge without exposing worker state" do
    issued = issue

    get fints_item_fints_challenge_url(@item, issued.token)

    assert_response :success
    assert_select "input[name=tan][type=password]"
    assert_not_includes response.body, "private-worker-state"
    assert_not_includes response.body, "dummy-pin"
    assert_not_includes response.body, "dummy-user"
  end

  test "correct TAN continues synchronously without a job or TAN in the URL" do
    issued = issue
    FintsItem.any_instance.expects(:continue_fints_challenge!).with(
      operation: "discover",
      worker_state: "private-worker-state",
      tan: "123456",
      worker: instance_of(Fints::WorkerClient)
    ).returns(success)

    assert_no_enqueued_jobs do
      post continue_fints_item_fints_challenge_url(@item, issued.token),
           params: { tan: "123456" },
           as: :json
    end

    assert_response :success
    assert_equal "completed", response.parsed_body["status"]
    assert_not_includes request.url, "123456"
    assert_not FintsChallenge.exists?(issued.challenge.id)
  end

  test "completed sync challenge schedules linked account materialization" do
    issued = issue(operation: :sync)
    FintsItem.any_instance.stubs(:continue_fints_challenge!).returns(success)
    FintsItem.any_instance.expects(:schedule_account_syncs).once.returns([])

    post continue_fints_item_fints_challenge_url(@item, issued.token),
         params: { tan: "123456" },
         as: :json

    assert_response :success
    assert_equal "completed", response.parsed_body["status"]
  end

  test "wrong TAN returns a safe terminal failure and removes state" do
    issued = issue
    FintsItem.any_instance.stubs(:continue_fints_challenge!).returns(
      Fints::WorkerClient::Failure.new("AUTHENTICATION_FAILED", "The bank rejected the confirmation.", [])
    )

    post continue_fints_item_fints_challenge_url(@item, issued.token),
         params: { tan: "wrong-secret-tan" },
         as: :json

    assert_response :unprocessable_entity
    assert_equal "The bank rejected the confirmation.", response.parsed_body["error"]
    assert_not_includes response.body, "wrong-secret-tan"
    assert_not FintsChallenge.exists?(issued.challenge.id)
  end

  test "missing TAN keeps the challenge available" do
    issued = issue

    post continue_fints_item_fints_challenge_url(@item, issued.token), params: { tan: "" }

    assert_response :unprocessable_entity
    assert_includes response.body, "Enter the TAN supplied by your bank."
    assert FintsChallenge.exists?(issued.challenge.id)
  end

  test "parameter filtering redacts TAN and FinTS secrets" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      "tan" => "secret-tan",
      "pin" => "secret-pin",
      "fints_user_id" => "secret-user",
      "worker_state" => "secret-state"
    )

    assert_equal [ "[FILTERED]" ], filtered.values.uniq
  end

  test "a challenge cannot be used by another admin in the same family" do
    issued = issue
    other = @family.users.create!(
      email: "other-fints-admin@example.com",
      password: user_password_test,
      role: "admin",
      onboarded_at: Time.current,
      ui_layout: "dashboard"
    )
    sign_in other

    get fints_item_fints_challenge_url(@item, issued.token)

    assert_response :not_found
    assert FintsChallenge.exists?(issued.challenge.id)
  end

  test "an invalid or manipulated token is rejected" do
    get fints_item_fints_challenge_url(@item, "x" * 43)

    assert_response :not_found
  end

  test "an expired challenge is rejected and removed" do
    issued = issue(expires_at: 1.second.ago)

    get fints_item_fints_challenge_url(@item, issued.token)

    assert_response :gone
    assert_not FintsChallenge.exists?(issued.challenge.id)
  end

  test "cancel removes challenge state" do
    issued = issue

    delete cancel_fints_item_fints_challenge_url(@item, issued.token), as: :json

    assert_response :no_content
    assert_not FintsChallenge.exists?(issued.challenge.id)
  end

  test "a challenge cannot be submitted twice" do
    issued = issue
    FintsItem.any_instance.stubs(:continue_fints_challenge!).returns(success)
    post continue_fints_item_fints_challenge_url(@item, issued.token), as: :json, params: { tan: "123456" }

    post continue_fints_item_fints_challenge_url(@item, issued.token), as: :json, params: { tan: "123456" }

    assert_response :not_found
  end

  test "decoupled challenge uses a bounded request with no TAN" do
    issued = issue(type: "decoupled")
    FintsItem.any_instance.expects(:continue_fints_challenge!).with(
      operation: "discover",
      worker_state: "private-worker-state",
      tan: nil,
      worker: instance_of(Fints::WorkerClient)
    ).returns(success)

    assert_no_enqueued_jobs do
      post continue_fints_item_fints_challenge_url(@item, issued.token), as: :json
    end

    assert_response :success
  end

  test "decoupled pending response creates a new single-use challenge" do
    issued = issue(type: "decoupled")
    FintsItem.any_instance.stubs(:continue_fints_challenge!).returns(worker_challenge(type: "decoupled", message: "Still pending"))

    post continue_fints_item_fints_challenge_url(@item, issued.token), as: :json

    assert_response :conflict
    assert_equal "challenge_required", response.parsed_body["status"]
    assert_not_equal issued.token, response.parsed_body["challenge_id"]
    assert_equal 1, FintsChallenge.count
  end

  test "decoupled failure is terminal" do
    issued = issue(type: "decoupled")
    FintsItem.any_instance.stubs(:continue_fints_challenge!).returns(
      Fints::WorkerClient::Failure.new("BANK_ERROR", "The bank declined the request.", [])
    )

    post continue_fints_item_fints_challenge_url(@item, issued.token), as: :json

    assert_response :unprocessable_entity
    assert_equal 0, FintsChallenge.count
  end

  test "worker timeout during continue is safe and terminal" do
    issued = issue(type: "decoupled")
    FintsItem.any_instance.stubs(:continue_fints_challenge!).raises(Fints::WorkerClient::TimeoutError, "FinTS worker timed out")

    post continue_fints_item_fints_challenge_url(@item, issued.token), as: :json

    assert_response :bad_gateway
    assert_equal "The bank confirmation could not be completed.", response.parsed_body["error"]
    assert_equal 0, FintsChallenge.count
  end

  test "a second challenge is rendered using a new token" do
    issued = issue
    FintsItem.any_instance.stubs(:continue_fints_challenge!).returns(worker_challenge(message: "Enter another TAN"))

    post continue_fints_item_fints_challenge_url(@item, issued.token), params: { tan: "123456" }

    assert_response :see_other
    assert_not_includes response.location, issued.token
    follow_redirect!
    assert_includes response.body, "Enter another TAN"
  end

  test "matrix image is available only through an authorized challenge" do
    issued = issue(image: tiny_png)

    get fints_item_fints_challenge_url(@item, issued.token)

    assert_response :success
    assert_select "img[src^='data:image/png;base64,']", count: 1
  end

  private

    def issue(type: "tan", message: "Confirm with bank", image: nil, expires_at: 5.minutes.from_now, operation: :discover)
      FintsChallenge.issue!(
        result: worker_challenge(type: type, message: message, image: image),
        operation: operation,
        family: @family,
        user: @user,
        fints_item: @item,
        expires_at: expires_at
      )
    end

    def worker_challenge(type: "tan", message: "Confirm with bank", image: nil)
      Fints::WorkerClient::Challenge.new(type, message, nil, image, "private-worker-state")
    end

    def success
      Fints::WorkerClient::Success.new("new-client-state", nil, nil, [])
    end

    def tiny_png
      "data:image/png;base64,iVBORw0KGgo="
    end
end
