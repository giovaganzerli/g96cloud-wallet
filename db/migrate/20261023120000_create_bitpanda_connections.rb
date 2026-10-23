class CreateBitpandaConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :bitpanda_items, id: :uuid do |t|
      t.references :family, null: false, type: :uuid, foreign_key: true
      t.string :name, null: false
      t.text :api_key, null: false
      t.string :status, null: false, default: "good"
      t.boolean :scheduled_for_deletion, null: false, default: false
      t.timestamps
    end

    create_table :bitpanda_accounts, id: :uuid do |t|
      t.references :bitpanda_item, null: false, type: :uuid, foreign_key: true
      t.string :account_id, null: false
      t.string :name, null: false
      t.string :currency, null: false, default: "EUR"
      t.text :raw_payload
      t.timestamps
      t.index [ :bitpanda_item_id, :account_id ], unique: true
    end
  end
end
