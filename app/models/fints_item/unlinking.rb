# frozen_string_literal: true

module FintsItem::Unlinking
  extend ActiveSupport::Concern

  def unlink_all!(dry_run: false)
    fints_accounts.map do |provider_account|
      links = provider_account.account_provider ? [ provider_account.account_provider ] : []
      result = { provider_account_id: provider_account.id, provider_link_ids: links.map(&:id) }
      links.each(&:destroy!) unless dry_run
      result
    end
  end
end
