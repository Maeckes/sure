# frozen_string_literal: true

require "test_helper"

class Fints::ProfileTest < ActiveSupport::TestCase
  test "ING values come only from the registered profile" do
    profile = Fints::Profile.resolve(
      id: "ing", bank_name: "Untrusted", bank_code: "00000000", endpoint: "https://untrusted.example/fints"
    )

    assert_equal "ING Deutschland", profile.fetch(:bank_name)
    assert_equal "50010517", profile.fetch(:bank_code)
    assert_equal "https://fints.ing.de/fints/", profile.fetch(:endpoint)
  end

  test "custom profile retains user-provided bank details for model validation" do
    profile = Fints::Profile.resolve(
      id: "custom", bank_name: "Example Bank", bank_code: "12345678", endpoint: "https://bank.example/fints"
    )

    assert_equal "Example Bank", profile.fetch(:bank_name)
    assert_equal "12345678", profile.fetch(:bank_code)
    assert_equal "https://bank.example/fints", profile.fetch(:endpoint)
  end
end
