# frozen_string_literal: true

require "test_helper"
require "tempfile"

class Fints::WorkerClientTest < ActiveSupport::TestCase
  setup do
    @credentials = {
      bank_code: "50010517", endpoint: "https://bank.example/fints",
      user_id: "dummy-user", customer_id: nil, pin: "dummy-pin",
      client_state: nil, tan_mechanism: nil, tan_medium: nil
    }
  end

  test "parses a strict success response and sends credentials only through stdin" do
    response = success_response
    script = ruby_worker("request = JSON.parse(STDIN.read); STDOUT.write(JSON.generate(#{response.inspect}.merge('observedOperation' => request['operation'])))")
    client = client_for(script)

    result = client.call(operation: :discover, credentials: @credentials)

    assert_instance_of Fints::WorkerClient::Success, result
    assert_equal "Checking", result.accounts.first["name"]
  ensure
    script&.close!
  end

  test "rejects product ids that are not exactly 25 characters before spawning the worker" do
    script = ruby_worker("raise 'must not run'")

    [ "1" * 24, "1" * 26 ].each do |product_id|
      client = Fints::WorkerClient.new(executable: RbConfig.ruby, script: script.path, product_id: product_id)
      error = assert_raises(Fints::WorkerClient::ConfigurationError) do
        client.call(operation: :discover, credentials: @credentials)
      end
      assert_equal "FinTS product id must be exactly 25 characters", error.message
    end
  ensure
    script&.close!
  end

  test "returns a typed challenge without persisting a TAN" do
    script = ruby_worker("STDIN.read; STDOUT.write(JSON.generate({kind: 'challenge', challengeType: 'tan', message: 'Confirm', workerState: 'opaque'}))")
    result = client_for(script).call(operation: :discover, credentials: @credentials)

    assert_instance_of Fints::WorkerClient::Challenge, result
    assert_equal "opaque", result.worker_state
  ensure
    script&.close!
  end

  test "accepts bounded decimal-string holdings without converting them to floats" do
    response = success_response
    account = response.fetch("accounts").first
    account["holdings"] = [ {
      "isin" => "DE000DUMMY01", "name" => "Dummy fund",
      "quantity" => "12.34567890123456789", "unitPrice" => "101.23456789",
      "currency" => "EUR", "valuationDate" => "2026-10-15",
      "totalValue" => "1249.81", "acquisitionPrice" => "87.654321"
    } ]
    account["holdingsSync"] = { "status" => "completed", "received" => 1, "normalized" => 1, "discarded" => 0 }
    script = ruby_worker("STDIN.read; STDOUT.write(JSON.generate(#{response.inspect}))")

    result = client_for(script).call(operation: :holdings, credentials: @credentials, remoteAccountKeys: [ "a" * 64 ])

    assert_equal "12.34567890123456789", result.accounts.first.dig("holdings", 0, "quantity")
    assert_instance_of String, result.accounts.first.dig("holdings", 0, "unitPrice")
  ensure
    script&.close!
  end

  test "rejects numeric holding decimals" do
    response = success_response
    account = response.fetch("accounts").first
    account["holdings"] = [ {
      "isin" => "DE000DUMMY01", "name" => "Dummy fund", "quantity" => 12.5,
      "unitPrice" => "1", "currency" => "EUR", "valuationDate" => "2026-10-15",
      "totalValue" => "12.5", "acquisitionPrice" => nil
    } ]
    account["holdingsSync"] = { "status" => "completed", "received" => 1, "normalized" => 1, "discarded" => 0 }
    script = ruby_worker("STDIN.read; STDOUT.write(JSON.generate(#{response.inspect}))")

    assert_raises(Fints::WorkerClient::ProtocolError) do
      client_for(script).call(operation: :holdings, credentials: @credentials, remoteAccountKeys: [ "a" * 64 ])
    end
  ensure
    script&.close!
  end

  test "accepts a bounded PNG matrix challenge" do
    image = "data:image/png;base64,iVBORw0KGgo="
    script = ruby_worker("STDIN.read; STDOUT.write(JSON.generate({kind: 'challenge', challengeType: 'tan', message: 'Confirm', challengeImage: '#{image}', workerState: 'opaque'}))")

    result = client_for(script).call(operation: :discover, credentials: @credentials)

    assert_equal image, result.challenge_image
  ensure
    script&.close!
  end

  test "rejects invalid challenge image content and media types" do
    script = ruby_worker("STDIN.read; STDOUT.write(JSON.generate({kind: 'challenge', challengeType: 'tan', message: 'Confirm', challengeImage: 'data:text/html;base64,PHNjcmlwdD4=', workerState: 'opaque'}))")

    assert_raises(Fints::WorkerClient::ProtocolError) do
      client_for(script).call(operation: :discover, credentials: @credentials)
    end
  ensure
    script&.close!
  end

  test "rejects invalid JSON" do
    script = ruby_worker("STDIN.read; STDOUT.write('not-json')")
    assert_raises(Fints::WorkerClient::ProtocolError) { client_for(script).call(operation: :discover, credentials: @credentials) }
  ensure
    script&.close!
  end

  test "rejects unknown structured error codes" do
    script = ruby_worker("STDIN.read; STDOUT.write(JSON.generate({kind: 'error', code: 'PRIVATE', message: 'no'}))")
    assert_raises(Fints::WorkerClient::ProtocolError) { client_for(script).call(operation: :discover, credentials: @credentials) }
  ensure
    script&.close!
  end

  test "rejects oversized output" do
    script = ruby_worker("STDIN.read; STDOUT.write('x' * 1025)")
    assert_raises(Fints::WorkerClient::ProtocolError) { client_for(script, output_limit: 1024).call(operation: :discover, credentials: @credentials) }
  ensure
    script&.close!
  end

  test "times out and does not include secrets in the exception" do
    script = ruby_worker("STDIN.read; sleep 2")
    error = assert_raises(Fints::WorkerClient::TimeoutError) { client_for(script, timeout: 0.05).call(operation: :discover, credentials: @credentials) }
    assert_not_includes error.message, "dummy-user"
    assert_not_includes error.message, "dummy-pin"
  ensure
    script&.close!
  end

  test "rejects unexpected process exit without exposing stderr" do
    script = ruby_worker("STDIN.read; STDERR.write('dummy-pin'); exit 2")
    error = assert_raises(Fints::WorkerClient::ProcessError) { client_for(script).call(operation: :discover, credentials: @credentials) }
    assert_not_includes error.message, "dummy-pin"
  ensure
    script&.close!
  end

  private

    def client_for(script, timeout: 1, output_limit: 1.megabyte)
      Fints::WorkerClient.new(executable: RbConfig.ruby, script: script.path, product_id: "1234567890123456789012345", timeout: timeout, output_limit: output_limit)
    end

    def ruby_worker(body)
      Tempfile.new([ "fints-worker", ".rb" ]).tap do |file|
        file.write("require 'json'\n#{body}\n")
        file.flush
      end
    end

    def success_response
      {
        "kind" => "success", "clientState" => "opaque", "tanMechanism" => nil, "tanMedium" => nil,
        "accounts" => [ {
          "remoteAccountKey" => "a" * 64, "name" => "Checking", "currency" => "EUR",
          "transactions" => [], "transactionSync" => { "status" => "not_requested" },
          "holdings" => [],
          "holdingsSync" => { "status" => "not_requested", "received" => 0, "normalized" => 0, "discarded" => 0 }
        } ]
      }
    end
end
