# frozen_string_literal: true

class FintsAccount < ApplicationRecord
  include CurrencyNormalizable

  belongs_to :fints_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :remote_account_key, :name, :currency, presence: true
  validates :remote_account_key, uniqueness: { scope: :fints_item_id }

  scope :unlinked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :needs_setup, -> { unlinked.where(ignored: false) }

  def suggested_subtype
    normalized = remote_account_type.to_s.downcase
    return "savings" if normalized.match?(/saving|sparen|tagesgeld|extra|term|deposit/)

    "checking"
  end

  def link_to_existing!(linked_account)
    raise ArgumentError, "account must belong to the same family" unless linked_account.family_id == fints_item.family_id
    raise ArgumentError, "only depository accounts can be linked" unless linked_account.accountable_type == "Depository"

    create_account_provider!(account: linked_account)
  end

  def create_and_link_account!(name: self.name, subtype: suggested_subtype)
    raise ArgumentError, "unsupported subtype" unless Depository::SUBTYPES.key?(subtype)

    transaction do
      depository = Depository.create!(subtype: subtype)
      linked = fints_item.family.accounts.create!(
        accountable: depository, name: name, currency: currency,
        balance: current_balance || 0, cash_balance: current_balance || 0,
        institution_name: fints_item.bank_name
      )
      create_account_provider!(account: linked)
      linked
    end
  end
end
