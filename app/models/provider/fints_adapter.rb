# frozen_string_literal: true

require "uri"

class Provider::FintsAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("FintsAccount", self)

  def self.supported_account_types = %w[Depository Investment]
  def provider_name = "fints"
  def item = provider_account.fints_item
  def can_delete_holdings? = false
  def institution_name = item.bank_name
  def institution_domain = URI.parse(item.endpoint).host
  def institution_url = item.endpoint
  def raw_payload = nil
end
