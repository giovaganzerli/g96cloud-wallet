class IncreaseUnitPricePrecision < ActiveRecord::Migration[8.1]
  def up
    # Preserve at least the existing integer range while allowing small token
    # prices to survive both the quote cache and canonical financial records.
    change_column :security_prices, :price, :decimal, precision: 34, scale: 18
    change_column :holdings, :price, :decimal, precision: 34, scale: 18
    change_column :trades, :price, :decimal, precision: 34, scale: 18
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Reducing unit price precision would discard stored financial data"
  end
end
