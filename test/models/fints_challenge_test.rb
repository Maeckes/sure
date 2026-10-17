# frozen_string_literal: true

require_relative "../support/fints_test_helper"

class FintsChallengeTest < ActiveSupport::TestCase
  include FintsTestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
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

  test "issues an opaque random token and stores only its digest" do
    first = issue
    second = issue

    assert_match(/\A[A-Za-z0-9_-]{40,100}\z/, first.token)
    assert_not_equal first.token, second.token
    assert_not_equal first.token, first.challenge.token_digest
    assert_equal Digest::SHA256.hexdigest(first.token), first.challenge.token_digest
  end

  test "encrypts worker and display state at rest" do
    issued = issue(
      worker_state: "private-worker-state",
      message: "Private bank message",
      challenge_html: "<p>Private HTML</p>",
      challenge_image: tiny_png
    )
    raw = FintsChallenge.connection.select_one(<<~SQL.squish)
      SELECT worker_state, message, challenge_html, challenge_image
      FROM fints_challenges WHERE id = '#{issued.challenge.id}'
    SQL

    assert raw.values.none? { _1.include?("private") }
    assert raw.values.none? { _1.include?("iVBOR") }
    assert_equal "private-worker-state", issued.challenge.reload.worker_state
  end

  test "never persists a TAN" do
    issued = issue
    @item.expects(:continue_fints_challenge!).with(
      operation: "discover",
      worker_state: "private-worker-state",
      tan: "654321",
      worker: anything
    ).returns(success)

    FintsChallenge.continue!(
      token: issued.token,
      family: @family,
      user: @user,
      fints_item: @item,
      tan: "654321",
      worker: mock
    )

    assert_equal 0, FintsChallenge.count
    assert_not_includes FintsChallenge.column_names, "tan"
  end

  test "successful continuation is single use" do
    issued = issue
    @item.stubs(:continue_fints_challenge!).returns(success)

    FintsChallenge.continue!(token: issued.token, family: @family, user: @user, fints_item: @item)

    assert_raises(FintsChallenge::Invalid) do
      FintsChallenge.continue!(token: issued.token, family: @family, user: @user, fints_item: @item)
    end
  end

  test "a second challenge keeps the original deadline and replaces the token" do
    issued = issue
    deadline = issued.challenge.expires_at
    @item.stubs(:continue_fints_challenge!).returns(worker_challenge(message: "Second challenge"))

    continuation = FintsChallenge.continue!(
      token: issued.token,
      family: @family,
      user: @user,
      fints_item: @item
    )

    assert_not_equal issued.token, continuation.issued.token
    assert_equal deadline.to_i, continuation.issued.challenge.expires_at.to_i
    assert_equal "Second challenge", continuation.issued.challenge.message
    assert_equal 1, FintsChallenge.count
  end

  test "rejects an expired challenge and removes its state" do
    issued = issue(expires_at: 1.second.ago)

    assert_raises(FintsChallenge::Expired) do
      FintsChallenge.authorized!(token: issued.token, family: @family, user: @user, fints_item: @item)
    end
    assert_not FintsChallenge.exists?(issued.challenge.id)
  end

  test "atomic consumption removes state that expires while being claimed" do
    issued = issue
    issued.challenge.update_column(:expires_at, 1.second.ago)

    assert_raises(FintsChallenge::Expired) { issued.challenge.consume! }
    assert_not FintsChallenge.exists?(issued.challenge.id)
  end

  test "rejects a different user in the same family" do
    issued = issue

    assert_raises(FintsChallenge::Invalid) do
      FintsChallenge.authorized!(
        token: issued.token,
        family: @family,
        user: users(:family_member),
        fints_item: @item
      )
    end
  end

  test "rejects a different family" do
    issued = issue

    assert_raises(FintsChallenge::Invalid) do
      FintsChallenge.authorized!(
        token: issued.token,
        family: families(:empty),
        user: users(:empty),
        fints_item: @item
      )
    end
  end

  test "cancel destroys the challenge" do
    issued = issue
    issued.challenge.cancel!

    assert_not FintsChallenge.exists?(issued.challenge.id)
  end

  test "rejects unvalidated image data" do
    assert_raises(ActiveRecord::RecordInvalid) do
      issue(challenge_image: "data:text/html;base64,PHNjcmlwdD4=")
    end
  end

  private

    def issue(expires_at: 5.minutes.from_now, **challenge_options)
      FintsChallenge.issue!(
        result: worker_challenge(**challenge_options),
        operation: :discover,
        family: @family,
        user: @user,
        fints_item: @item,
        expires_at: expires_at
      )
    end

    def worker_challenge(type: "tan", message: "Enter TAN", challenge_html: nil, challenge_image: nil, worker_state: "private-worker-state")
      Fints::WorkerClient::Challenge.new(type, message, challenge_html, challenge_image, worker_state)
    end

    def success
      Fints::WorkerClient::Success.new("new-client-state", nil, nil, [])
    end

    def tiny_png
      "data:image/png;base64,iVBORw0KGgo="
    end
end
