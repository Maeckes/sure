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

  test "returns a typed challenge without persisting a TAN" do
    script = ruby_worker("STDIN.read; STDOUT.write(JSON.generate({kind: 'challenge', challengeType: 'tan', message: 'Confirm', workerState: 'opaque'}))")
    result = client_for(script).call(operation: :discover, credentials: @credentials)

    assert_instance_of Fints::WorkerClient::Challenge, result
    assert_equal "opaque", result.worker_state
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
      Fints::WorkerClient.new(executable: RbConfig.ruby, script: script.path, product_id: "dummy-product", timeout: timeout, output_limit: output_limit)
    end

    def ruby_worker(body)
      Tempfile.create([ "fints-worker", ".rb" ]).tap do |file|
        file.write("require 'json'\n#{body}\n")
        file.flush
      end
    end

    def success_response
      {
        "kind" => "success", "clientState" => "opaque", "tanMechanism" => nil, "tanMedium" => nil,
        "accounts" => [ {
          "remoteAccountKey" => "a" * 64, "name" => "Checking", "currency" => "EUR",
          "transactions" => [], "transactionSync" => { "status" => "not_requested" }
        } ]
      }
    end
end
