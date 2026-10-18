# frozen_string_literal: true

class Fints::Profile
  InvalidProfile = Class.new(ArgumentError)

  ING = {
    bank_name: "ING Deutschland",
    bank_code: "50010517",
    endpoint: "https://fints.ing.de/fints/"
  }.freeze

  def self.resolve(id:, bank_name:, bank_code:, endpoint:)
    case id.to_s
    when "ing"
      ING
    when "custom"
      { bank_name: bank_name, bank_code: bank_code, endpoint: endpoint }
    else
      raise InvalidProfile, "Select a supported FinTS bank profile."
    end
  end
end
