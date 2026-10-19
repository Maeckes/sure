# frozen_string_literal: true

class Fints::HoldingsImportError < ArgumentError
  attr_reader :code

  def initialize(code)
    @code = code.to_s
    super("FinTS holdings import failed (#{@code})")
  end
end
