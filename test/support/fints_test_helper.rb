# frozen_string_literal: true

require_relative "../test_helper"

module FintsTestHelper
  extend ActiveSupport::Concern

  included do
    setup do
      Rails.configuration.stubs(:app_mode).returns("self_hosted".inquiry)
    end
  end
end
