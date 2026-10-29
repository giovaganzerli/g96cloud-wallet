class CreateAccountRoundUpSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :account_round_up_settings, id: :uuid do |t|
      t.references :account,
                   null: false,
                   type: :uuid,
                   foreign_key: { on_delete: :cascade },
                   index: { unique: true }

      # Optional so the row can exist while the feature is off. A null
      # destination is only ever persisted for a disabled setting; the model
      # requires one as soon as `enabled` flips on.
      t.references :destination_account,
                   type: :uuid,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.boolean :enabled, null: false, default: false
      t.integer :multiplier, null: false, default: 1

      t.timestamps
    end

    add_check_constraint :account_round_up_settings,
                         "multiplier IN (1, 2, 3, 4, 5, 10)",
                         name: "account_round_up_settings_multiplier_check"
  end
end
