class CreateScalableCapitalConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :scalable_capital_items, id: :uuid do |t|
      t.references :family, null: false, type: :uuid, foreign_key: true
      t.string :name, null: false
      t.string :status, null: false, default: "requires_update"
      t.boolean :scheduled_for_deletion, null: false, default: false
      t.timestamps
    end

    create_table :scalable_capital_accounts, id: :uuid do |t|
      t.references :scalable_capital_item, null: false, type: :uuid, foreign_key: true
      t.string :portfolio_id, null: false
      t.string :provider_account_id, null: false
      t.string :name, null: false
      t.string :currency, null: false, default: "EUR"
      t.jsonb :raw_payload, null: false, default: {}
      t.timestamps
      t.index [ :scalable_capital_item_id, :portfolio_id ], unique: true, name: "index_scalable_accounts_on_item_and_portfolio"
    end
  end
end
