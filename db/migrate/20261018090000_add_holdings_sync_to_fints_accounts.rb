class AddHoldingsSyncToFintsAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :fints_accounts, :holdings_supported, :boolean, null: false, default: false
    add_column :fints_accounts, :holdings_status, :string, null: false, default: "not_requested"
    add_column :fints_accounts, :holdings_synced_on, :date

    add_check_constraint :fints_accounts,
      "holdings_status IN ('not_requested', 'completed', 'unsupported', 'unavailable')",
      name: "chk_fints_accounts_holdings_status"
  end
end
