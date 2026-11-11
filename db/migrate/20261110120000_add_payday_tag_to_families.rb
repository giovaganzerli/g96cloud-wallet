class AddPaydayTagToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :payday_tag_id, :uuid
    add_index :families, :payday_tag_id
    add_foreign_key :families, :tags, column: :payday_tag_id, on_delete: :nullify
  end
end
