class CreateFintsChallenges < ActiveRecord::Migration[8.1]
  def change
    create_table :fints_challenges, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :fints_item, null: false, foreign_key: true, type: :uuid
      t.string :token_digest, null: false
      t.string :operation, null: false
      t.string :challenge_type, null: false
      t.text :message, null: false
      t.text :challenge_html
      t.text :challenge_image
      t.text :worker_state, null: false
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :fints_challenges, :token_digest, unique: true
    add_index :fints_challenges, :expires_at
  end
end
