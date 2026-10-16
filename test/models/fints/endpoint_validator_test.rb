# frozen_string_literal: true

require "test_helper"

class Fints::EndpointValidatorTest < ActiveSupport::TestCase
  test "accepts a public HTTPS hostname" do
    assert Fints::EndpointValidator.validate!("https://bank.example/fints")
  end

  test "rejects non HTTPS and literal private addresses" do
    assert_raises(Fints::EndpointValidator::InvalidEndpoint) { Fints::EndpointValidator.validate!("http://bank.example/fints") }
    assert_raises(Fints::EndpointValidator::InvalidEndpoint) { Fints::EndpointValidator.validate!("https://127.0.0.1/fints") }
    assert_raises(Fints::EndpointValidator::InvalidEndpoint) { Fints::EndpointValidator.validate!("https://192.168.1.2/fints") }
  end

  test "rejects URL credentials" do
    assert_raises(Fints::EndpointValidator::InvalidEndpoint) { Fints::EndpointValidator.validate!("https://user:secret@bank.example/fints") }
  end
end
