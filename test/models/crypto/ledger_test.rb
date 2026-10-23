require "test_helper"

class Crypto::LedgerTest < ActiveSupport::TestCase
  setup do
    @item = bitpanda_items(:one)
    @snapshot = JSON.parse(file_fixture("bitpanda/snapshot.json").read)
    provider = stub(snapshot: @snapshot)
    @item.stubs(:provider).returns(provider)
    Account.any_instance.stubs(:sync_later)
    Security.stubs(:search_provider).returns([])
  end

  test "displays original timestamp native balance execution rate and trading fee" do
    rows = @snapshot["operations"].last["transactions"]
    rows.first["trade"].merge!("rate_with_fee" => "50000.12345678", "fee" => { "value" => "1", "asset_id" => "btc" })
    rows.first["fee_amount"] = { "value" => "0", "asset_id" => "btc" }
    rows.first["asset_balance_after"] = { "value" => "0.01", "asset_id" => "btc" }
    @snapshot["operations"].last["description"] = "Original exchange description"
    BitpandaItem::Syncer.new(@item).perform_sync(@item.syncs.create!)
    account = @item.accounts.sole
    rows = Crypto::Ledger.new(account, entries: account.entries.includes(:entryable)).rows
    buy = rows.find { |row| row.action == "buy" }
    assert_equal "Original exchange description", buy.description
    assert_equal Time.utc(2026, 10, 22, 12), buy.occurred_at
    assert_equal BigDecimal("0.01"), buy.quantity
    assert_equal BigDecimal("0.01"), buy.balance_after
    assert_equal 500, buy.euro_value
    assert_equal BigDecimal("50000.12345678"), buy.unit_price_eur
    assert_equal "EUR", buy.fees.sole[:symbol]
    assert_equal 1, buy.fees.sole[:quantity]
    assert_equal "bitpanda", buy.price_source
  end

  test "a zero cash crypto deposit is not displayed as a zero EUR valuation" do
    @snapshot["operations"] = [ { "operation_id" => "deposit", "operation_type" => "deposit", "transactions" => [ {
      "transaction_id" => "native-deposit", "asset_id" => "btc", "asset_amount" => { "value" => "0.01" },
      "flow" => "INCOMING", "credited_at" => "2026-10-22T12:00:00Z", "asset_balance_after" => { "value" => "0.01" }
    } ] } ]
    BitpandaItem::Syncer.new(@item).perform_sync(@item.syncs.create!)
    account = @item.accounts.sole
    row = Crypto::Ledger.new(account, entries: account.entries.includes(:entryable)).rows.sole
    assert_equal BigDecimal("0.01"), row.quantity
    assert_nil row.euro_value
    assert_nil row.unit_price_eur
    assert_equal BigDecimal("0.01"), row.balance_after
  end

  test "manual native balances include earlier pages and are independent of input order" do
    account = families(:dylan_family).accounts.create!(name: "Manual crypto", currency: "EUR", balance: 0, accountable: Crypto.new(subtype: "wallet"))
    late = Crypto::ActivityForm.new(account: account, description: "Later buy", kind: "buy", symbol: "BTC", quantity: "0.2", unit_price_eur: "100000", occurred_at: "2025-07-24T12:00")
    early = Crypto::ActivityForm.new(account: account, description: "Earlier buy", kind: "buy", symbol: "BTC", quantity: "0.1", unit_price_eur: "100000", occurred_at: "2025-07-23T12:00")
    assert late.save
    assert early.save
    row = Crypto::Ledger.new(account, entries: [ late.entry ]).rows.sole
    assert_equal BigDecimal("0.3"), row.balance_after
    assert_equal BigDecimal("20000"), row.euro_value
    early.entry.update!(excluded: true)
    assert_equal BigDecimal("0.2"), Crypto::Ledger.new(account, entries: [ late.entry ]).rows.sole.balance_after
  end
end
