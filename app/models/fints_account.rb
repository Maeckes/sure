# frozen_string_literal: true

class FintsAccount < ApplicationRecord
  include CurrencyNormalizable

  HOLDINGS_STATUSES = %w[not_requested completed unsupported unavailable].freeze

  belongs_to :fints_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :remote_account_key, :name, :currency, presence: true
  validates :remote_account_key, uniqueness: { scope: :fints_item_id }
  validates :holdings_status, inclusion: { in: HOLDINGS_STATUSES }

  scope :unlinked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :needs_setup, -> { unlinked.where(ignored: false) }

  def suggested_subtype
    return "brokerage" if investment?

    normalized = remote_account_type.to_s.downcase
    return "savings" if normalized.match?(/saving|sparen|tagesgeld|extra|term|deposit/)

    "checking"
  end

  def suggested_accountable_type
    investment? ? "Investment" : "Depository"
  end

  def investment?
    holdings_supported?
  end

  def link_to_existing!(linked_account)
    raise ArgumentError, "account must belong to the same family" unless linked_account.family_id == fints_item.family_id
    raise ArgumentError, "account type does not match the FinTS account" unless linked_account.accountable_type == suggested_accountable_type
    raise ArgumentError, "remote account is already linked" if account_provider.present?
    raise ArgumentError, "account is already linked to a provider" if linked_account.account_providers.exists?

    create_account_provider!(account: linked_account)
  end

  def create_and_link_account!(name: self.name, subtype: suggested_subtype)
    accountable_type = suggested_accountable_type
    subtype_registry = accountable_type == "Investment" ? Investment::SUBTYPES : Depository::SUBTYPES
    raise ArgumentError, "unsupported subtype" unless subtype_registry.key?(subtype)

    transaction do
      linked = Account.create_and_sync(
        {
          family: fints_item.family, name: name, currency: currency,
          accountable_type: accountable_type, accountable_attributes: { subtype: subtype },
          balance: investment? ? 0 : current_balance || 0,
          cash_balance: investment? ? 0 : current_balance || 0,
          institution_name: fints_item.bank_name
        },
        skip_initial_sync: true
      )
      create_account_provider!(account: linked)
      linked
    end
  end
end
