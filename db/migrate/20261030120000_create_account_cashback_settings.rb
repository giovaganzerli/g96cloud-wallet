class CreateAccountCashbackSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :account_cashback_settings, id: :uuid do |t|
      t.references :account, null: false, foreign_key: true, type: :uuid, index: { unique: true }
      t.boolean :enabled, null: false, default: false
      t.decimal :percentage, precision: 5, scale: 2
      t.timestamps
    end
  end
end
