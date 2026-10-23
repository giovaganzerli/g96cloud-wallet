class AddOccurredAtToEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :entries, :occurred_at, :datetime, precision: 6
    add_index :entries, [ :account_id, :occurred_at ]
  end
end
