# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require "base64"

class Fints::WorkerClient
  Error = Class.new(StandardError)
  ConfigurationError = Class.new(Error)
  TimeoutError = Class.new(Error)
  ProtocolError = Class.new(Error)
  ProcessError = Class.new(Error)
  Challenge = Data.define(:challenge_type, :message, :challenge_html, :challenge_image, :worker_state)
  Failure = Data.define(:code, :message, :details)
  Success = Data.define(:client_state, :tan_mechanism, :tan_medium, :accounts)

  DEFAULT_TIMEOUT = 30
  DEFAULT_OUTPUT_LIMIT = 2.megabytes
  ERROR_CODES = %w[AUTHENTICATION_FAILED NETWORK_ERROR UNSUPPORTED BANK_ERROR].freeze

  def initialize(
    executable: Rails.configuration.x.fints.python_executable,
    script: Rails.configuration.x.fints.worker_path,
    product_id: Rails.configuration.x.fints.product_id,
    timeout: Rails.configuration.x.fints.worker_timeout,
    output_limit: Rails.configuration.x.fints.output_limit
  )
    @executable = executable
    @script = script
    @product_id = product_id
    @timeout = timeout || DEFAULT_TIMEOUT
    @output_limit = output_limit || DEFAULT_OUTPUT_LIMIT
  end

  def call(operation:, credentials:, **payload)
    raise ConfigurationError, "FinTS product id is not configured" if @product_id.blank?

    request = {
      operation: operation.to_s, productId: @product_id,
      bankCode: credentials.fetch(:bank_code), endpoint: credentials.fetch(:endpoint),
      userId: credentials.fetch(:user_id), customerId: credentials[:customer_id],
      pin: credentials.fetch(:pin), clientState: credentials[:client_state],
      tanMechanism: credentials[:tan_mechanism], tanMedium: credentials[:tan_medium]
    }.merge(payload)
    serialized = JSON.generate(request)
    raise ProtocolError, "FinTS worker request exceeded the size limit" if serialized.bytesize > @output_limit

    parse(run(serialized))
  end

  private

    def run(input)
      stdout_data = nil
      status = nil
      Open3.popen3({ "PYTHONUNBUFFERED" => "1" }, @executable.to_s, @script.to_s, unsetenv_others: true) do |stdin, stdout, stderr, wait_thread|
        stderr_reader = Thread.new { drain(stderr) }
        begin
          Timeout.timeout(@timeout) do
            stdin.write(input)
            stdin.close
            stdout_data = stdout.read(@output_limit + 1).to_s
            raise ProtocolError, "FinTS worker response exceeded the size limit" if stdout_data.bytesize > @output_limit
            status = wait_thread.value
          end
        rescue ::Timeout::Error
          terminate(wait_thread.pid)
          raise TimeoutError, "FinTS worker timed out"
        rescue ProtocolError
          terminate(wait_thread.pid)
          raise
        ensure
          stdin.close unless stdin.closed?
          stderr_reader.join(1)
          stderr_reader.kill if stderr_reader.alive?
        end
      end
      raise ProcessError, "FinTS worker exited unexpectedly" unless status&.success?

      stdout_data
    end

    def drain(io)
      loop { break if io.readpartial(16.kilobytes).nil? }
    rescue EOFError, IOError
      nil
    end

    def terminate(pid)
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end

    def parse(raw)
      value = JSON.parse(raw)
      raise ProtocolError, "Invalid FinTS worker response" unless value.is_a?(Hash)

      case value["kind"]
      when "success" then parse_success(value)
      when "challenge" then parse_challenge(value)
      when "error" then parse_error(value)
      else raise ProtocolError, "Invalid FinTS worker response"
      end
    rescue JSON::ParserError
      raise ProtocolError, "Invalid FinTS worker response"
    end

    def parse_success(value)
      accounts = value["accounts"]
      raise ProtocolError, "Invalid FinTS worker response" unless accounts.is_a?(Array) && accounts.size <= 1_000 && accounts.all? { valid_account?(_1) }
      raise ProtocolError, "Invalid FinTS worker response" unless optional_string?(value["clientState"], 2.megabytes)
      raise ProtocolError, "Invalid FinTS worker response" unless optional_string?(value["tanMechanism"], 100)
      raise ProtocolError, "Invalid FinTS worker response" unless optional_string?(value["tanMedium"], 200)

      Success.new(value["clientState"], value["tanMechanism"], value["tanMedium"], accounts)
    end

    def parse_challenge(value)
      required_strings!(value, "challengeType", "message", "workerState")
      raise ProtocolError, "Invalid FinTS worker response" unless %w[tan decoupled].include?(value["challengeType"])
      raise ProtocolError, "Invalid FinTS worker response" unless value["message"].bytesize <= 5_000
      raise ProtocolError, "Invalid FinTS worker response" unless optional_string?(value["challengeHtml"], 20_000)
      raise ProtocolError, "Invalid FinTS worker response" unless valid_challenge_image?(value["challengeImage"])
      raise ProtocolError, "Invalid FinTS worker response" unless value["workerState"].bytesize <= 2.megabytes

      Challenge.new(value["challengeType"], value["message"], value["challengeHtml"], value["challengeImage"], value["workerState"])
    end

    def parse_error(value)
      required_strings!(value, "code", "message")
      details = value["details"] || []
      raise ProtocolError, "Invalid FinTS worker response" unless ERROR_CODES.include?(value["code"])
      raise ProtocolError, "Invalid FinTS worker response" unless value["code"].bytesize <= 100 && value["message"].bytesize <= 2_000
      raise ProtocolError, "Invalid FinTS worker response" unless details.is_a?(Array) && details.size <= 10 && details.all? { _1.is_a?(Hash) && optional_string?(_1["code"], 100, required: true) && optional_string?(_1["message"], 500, required: true) }

      Failure.new(value["code"], value["message"], details)
    end

    def valid_account?(account)
      account.is_a?(Hash) && account["remoteAccountKey"].is_a?(String) && account["remoteAccountKey"].match?(/\A[0-9a-f]{64}\z/) &&
        optional_string?(account["name"], 500, required: true) && account["currency"].is_a?(String) && account["currency"].match?(/\A[A-Z]{3}\z/) &&
        (account["balance"].nil? || account["balance"].is_a?(Integer)) && account["transactions"].is_a?(Array) &&
        account["transactions"].size <= 100_000 && account["transactions"].all? { valid_transaction?(_1) } &&
        valid_transaction_sync?(account["transactionSync"])
    end

    def valid_transaction?(transaction)
      return false unless transaction.is_a?(Hash) && transaction["amount"].is_a?(Integer)
      return false unless transaction["bookingDate"].is_a?(String) && Date.iso8601(transaction["bookingDate"])
      return false unless transaction["currency"].is_a?(String) && transaction["currency"].match?(/\A[A-Z]{3}\z/)

      true
    rescue Date::Error
      false
    end

    def valid_transaction_sync?(value)
      return false unless value.is_a?(Hash) && %w[not_requested requested completed unsupported unavailable].include?(value["status"])
      return true unless value["status"] == "completed"

      Date.iso8601(value["startDate"])
      Date.iso8601(value["endDate"])
      true
    rescue Date::Error, TypeError
      false
    end

    def optional_string?(value, maximum, required: false)
      return !required if value.nil?

      value.is_a?(String) && value.present? && value.bytesize <= maximum
    end

    def valid_challenge_image?(value)
      return true if value.nil?
      return false unless value.is_a?(String) && value.bytesize <= 2.megabytes

      match = value.match(%r{\Adata:(image/(?:png|jpeg));base64,([A-Za-z0-9+/=]+)\z})
      return false unless match

      Base64.strict_decode64(match[2]).bytesize <= 1.megabyte
    rescue ArgumentError
      false
    end

    def required_strings!(value, *keys)
      raise ProtocolError, "Invalid FinTS worker response" unless keys.all? { value[_1].is_a?(String) && value[_1].present? }
    end
end
