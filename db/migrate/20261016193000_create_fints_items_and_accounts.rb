class CreateFintsItemsAndAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :fints_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :bank_name, null: false
      t.string :bank_code, null: false
      t.string :endpoint, null: false
      t.text :user_id, null: false
      t.text :customer_id
      t.text :pin, null: false
      t.text :client_state
      t.text :private_state
      t.string :tan_mechanism
      t.string :tan_medium
      t.string :status, null: false, default: "good"
      t.boolean :pending_account_setup, null: false, default: false
      t.boolean :scheduled_for_deletion, null: false, default: false
      t.timestamps
    end

    add_index :fints_items, :status

    create_table :fints_accounts, id: :uuid do |t|
      t.references :fints_item, null: false, foreign_key: true, type: :uuid
      t.string :remote_account_key, null: false
      t.string :name, null: false
      t.string :remote_account_type
      t.string :currency, null: false
      t.string :iban_mask
      t.string :account_fingerprint
      t.decimal :current_balance, precision: 19, scale: 4
      t.boolean :balance_available, null: false, default: false
      t.boolean :transactions_supported, null: false, default: false
      t.boolean :ignored, null: false, default: false
      t.date :transactions_synced_through
      t.date :history_synced_from
      t.timestamps
    end

    add_index :fints_accounts, [ :fints_item_id, :remote_account_key ], unique: true, name: "index_fints_accounts_on_item_and_remote_key"
    add_index :fints_accounts, :account_fingerprint
  end
end
