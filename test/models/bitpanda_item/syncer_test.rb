require "test_helper"
require "ostruct"

class BitpandaItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @item = bitpanda_items(:one)
    @sync = @item.syncs.create!
    @snapshot = JSON.parse(file_fixture("bitpanda/snapshot.json").read)
    @snapshot["date"] = Date.current.iso8601
    @provider = mock
    @provider.stubs(:snapshot).returns(@snapshot)
    @item.stubs(:provider).returns(@provider)
    Account.any_instance.stubs(:sync_later)
    Security.stubs(:search_provider).returns([])
  end

  test "repeated synchronization creates one Crypto exchange account and no duplicate activity" do
    2.times { syncer.perform_sync(@sync) }
    account = @item.accounts.sole
    assert_equal "Crypto", account.accountable_type
    assert_equal "exchange", account.accountable.subtype
    assert_equal "EUR", account.currency
    assert_equal 700, account.balance
    assert_equal 100, account.cash_balance
    assert_equal 1, @item.bitpanda_accounts.count
    assert_equal 1, account.holdings.where(account_provider: @item.bitpanda_accounts.sole.account_provider).count
    entries = account.entries.where(source: "bitpanda")
    assert_equal 2, entries.count
    assert_equal 500, entries.find_by!(external_id: "bitpanda_buy-btc").amount
    assert_equal(-600, entries.find_by!(external_id: "bitpanda_deposit-eur").amount)
    assert @item.reload.good?
  end

  test "inbound crypto deposit keeps an unknown movement price but estimates cost basis from the deposit-day quote" do
    @snapshot["portfolio"].first["balance"]["value"] = "0.015"
    @snapshot["portfolio"].first["currency_balance"]["value"] = "900"
    @snapshot["operations"] << {
      "operation_id" => "crypto-deposit", "operation_type" => "DEPOSIT", "transactions" => [ {
        "transaction_id" => "deposit-btc", "asset_id" => "btc",
        "asset_amount" => { "value" => "0.005", "asset_id" => "btc" },
        "flow" => "INCOMING", "credited_at" => "2026-10-21T12:00:00Z"
      } ]
    }
    quote = OpenStruct.new(date: Date.new(2026, 10, 21), price: BigDecimal("60000"), currency: "EUR")
    Security.any_instance.stubs(:find_or_fetch_price).returns(quote)

    syncer.perform_sync(@sync)

    account = @item.accounts.sole
    deposit = account.entries.find_by!(external_id: "bitpanda_deposit-btc")
    assert_equal 0, deposit.amount
    assert_equal 0, deposit.trade.price
    assert deposit.trade.estimated_cost_basis?
    assert_equal BigDecimal("60000"), deposit.trade.estimated_cost_basis_price.to_d
    assert_equal "2026-10-21", deposit.trade.extra.dig("cost_basis", "estimated_on")
    assert_not deposit.trade.extra.dig("bitpanda", "cost_basis_unknown")

    holding = account.current_holdings.sole
    expected = (BigDecimal("60000") * BigDecimal("0.005") + BigDecimal("500")) / BigDecimal("0.015")
    assert_equal Money.new(expected, "EUR"), holding.avg_cost
    assert holding.cost_basis_estimated?
    assert_equal I18n.t("holdings.cost_basis_sources.estimated"), holding.cost_basis_source_label
    assert_not_nil holding.trend
  end

  test "inbound crypto deposit without an exact-date quote stays unknown and records a warning" do
    @snapshot["portfolio"].first["balance"]["value"] = "0.015"
    @snapshot["portfolio"].first["currency_balance"]["value"] = "900"
    @snapshot["operations"] << {
      "operation_id" => "crypto-deposit", "operation_type" => "DEPOSIT", "transactions" => [ {
        "transaction_id" => "deposit-btc", "asset_id" => "btc",
        "asset_amount" => { "value" => "0.005", "asset_id" => "btc" },
        "flow" => "INCOMING", "credited_at" => "2026-10-21T12:00:00Z"
      } ]
    }
    Security.any_instance.stubs(:find_or_fetch_price).returns(nil)
    DebugLogEntry.expects(:capture).with(has_entries(provider_key: "bitpanda", category: "provider_sync_warning")).once

    syncer.perform_sync(@sync)

    account = @item.accounts.sole
    deposit = account.entries.find_by!(external_id: "bitpanda_deposit-btc")
    assert_not deposit.trade.estimated_cost_basis?
    assert deposit.trade.extra.dig("bitpanda", "cost_basis_unknown")

    holding = account.current_holdings.sole
    assert_nil holding.avg_cost
    assert_not holding.cost_basis_estimated?
    assert_nil holding.trend
  end

  test "invalid snapshots leave canonical accounts and financial records untouched" do
    @snapshot["portfolio"].first["balance"]["value"] = "NaN"
    assert_no_difference [ "Account.count", "BitpandaAccount.count", "Entry.count", "Holding.count" ] do
      assert_raises(Provider::Bitpanda::InvalidDataError) { syncer.perform_sync(@sync) }
    end
  end

  test "reclaim corrections are idempotent cash neutral and visibly require review" do
    @snapshot["operations"] << {
      "operation_id" => "reclaim", "operation_type" => "reclaim", "transactions" => [ {
        "transaction_id" => "reclaim-btc", "asset_id" => "btc",
        "asset_amount" => { "value" => "0.001", "asset_id" => "btc" },
        "flow" => "OUTGOING", "credited_at" => "2026-10-22T13:00:00Z"
      } ]
    }
    DebugLogEntry.expects(:capture).with(has_entries(provider_key: "bitpanda", family: @item.family, level: "warn")).twice
    2.times { syncer.perform_sync(@sync) }

    entries = @item.accounts.sole.entries.where(source: "bitpanda")
    assert_equal 3, entries.count
    entry = entries.find_by!(external_id: "bitpanda_reclaim-btc")
    assert_equal 0, entry.amount
    assert_equal BigDecimal("-0.001"), entry.trade.qty
    assert_equal "Transfer", entry.trade.investment_activity_label
    assert entry.trade.internal_movement?
    assert_nil entry.trade.realized_gain_loss
    assert entry.trade.extra.dig("bitpanda", "review_required")
    assert entry.trade.extra.dig("bitpanda", "cost_basis_unknown")
    assert_includes entry.name, I18n.t("bitpanda_items.activity_names.reclaim")
    assert @item.review_required?
    assert_not bitpanda_items(:other_family).review_required?
    assert_equal 700, @item.accounts.sole.balance
    assert_equal 100, @item.accounts.sole.cash_balance
  end

  test "crypto holdings use an exact base market data match rather than a fuzzy ticker" do
    matched = Security.create!(ticker: "CRYPTO:BTCUSD", name: "Bitcoin USD", offline: false)
    wrong = Security.new(ticker: "CRYPTO:BTCSTUSD", name: "Not Bitcoin")
    Security.stubs(:search_provider).returns([ wrong, matched ])
    resolver = mock(resolve: matched)
    Security::Resolver.expects(:new).with(
      matched.ticker, exchange_operating_mic: matched.exchange_operating_mic,
      country_code: matched.country_code, price_provider: matched.price_provider
    ).returns(resolver)
    syncer.perform_sync(@sync)
    assert_equal matched.id, @item.accounts.sole.holdings.sole.security_id
  end

  test "excluded correction trades remain excluded on resync and do not require review" do
    @snapshot["operations"] << {
      "operation_id" => "reclaim", "operation_type" => "reclaim", "transactions" => [ {
        "transaction_id" => "reclaim-btc", "asset_id" => "btc",
        "asset_amount" => { "value" => "0.001", "asset_id" => "btc" },
        "flow" => "OUTGOING", "credited_at" => "2026-10-22T13:00:00Z"
      } ]
    }
    DebugLogEntry.expects(:capture).with(has_entries(provider_key: "bitpanda", level: "warn")).once
    syncer.perform_sync(@sync)
    entries = @item.accounts.sole.entries.where(source: "bitpanda")
    correction = entries.find_by!(external_id: "bitpanda_reclaim-btc")
    correction.update!(excluded: true)

    assert_not @item.review_required?
    assert correction.protected_from_sync?
    syncer.perform_sync(@sync)

    assert correction.reload.excluded?
    assert correction.trade.extra.dig("bitpanda", "review_required"), "Retain original provider metadata for audit"
    assert_not @item.review_required?
    assert_equal 3, entries.count
    assert_equal 2, entries.where(excluded: false).count
  end

  test "excluded fiat corrections remain excluded on resync and do not require review" do
    @snapshot["operations"].first["operation_type"] = "refund"
    DebugLogEntry.expects(:capture).with(has_entries(provider_key: "bitpanda", level: "warn")).once
    syncer.perform_sync(@sync)
    correction = @item.accounts.sole.entries.find_by!(source: "bitpanda", external_id: "bitpanda_deposit-eur")
    assert @item.review_required?
    correction.update!(excluded: true)

    syncer.perform_sync(@sync)

    assert correction.reload.excluded?
    assert_not @item.review_required?
  end

  test "fuzzy crypto matches are rejected in favor of an offline exact asset" do
    Security.stubs(:search_provider).returns([ Security.new(ticker: "CRYPTO:BTCSTUSD") ])
    Security::Resolver.expects(:new).never
    syncer.perform_sync(@sync)
    security = @item.accounts.sole.holdings.sole.security
    assert_equal "CRYPTO:BTC", security.ticker
    assert security.offline?
  end

  test "Public API cryptocoin assets can resolve quoted pairs and fetch exact date reward prices" do
    matched = Security.create!(ticker: "BTCUSD", name: "Bitcoin USD", offline: false)
    Security.stubs(:search_provider).returns([ matched ])
    Security::Resolver.expects(:new).with(
      matched.ticker, exchange_operating_mic: matched.exchange_operating_mic,
      country_code: matched.country_code, price_provider: matched.price_provider
    ).returns(mock(resolve: matched))
    matched.expects(:find_or_fetch_price).with(date: Date.new(2026, 2, 24))
      .returns(OpenStruct.new(date: Date.new(2026, 2, 24), price: BigDecimal("50000"), currency: "USD"))
    @snapshot["operations"] << {
      "operation_id" => "reward", "operation_type" => "passive_earn_reward", "transactions" => [ {
        "transaction_id" => "reward-btc", "asset_id" => "btc", "asset_amount" => { "value" => "0.001" },
        "flow" => "INCOMING", "credited_at" => "2026-02-24T12:00:00Z"
      } ]
    }

    syncer.perform_sync(@sync)
    entry = @item.accounts.sole.entries.find_by!(source: "bitpanda", external_id: "bitpanda_reward-btc")
    assert_equal matched.id, entry.trade.security_id
    assert_equal BigDecimal("50000"), entry.trade.price
    assert_equal "USD", entry.currency
    assert_equal 0, entry.amount
    assert_equal "Dividend", entry.trade.investment_activity_label
  end

  test "an equity sharing a crypto symbol remains separate and offline" do
    @snapshot["assets"].first["type"] = "equity_security"
    Security.expects(:search_provider).never
    Security::Resolver.expects(:new).never

    2.times { syncer.perform_sync(@sync) }
    security = @item.accounts.sole.holdings.sole.security
    assert_equal "BITPANDA:BTC", security.ticker
    assert security.offline?
  end

  test "missing historical prices roll back the entire import rather than reporting partial success" do
    rows = @snapshot["operations"].last["transactions"]
    rows.pop
    DebugLogEntry.expects(:capture).with(has_entries(provider_key: "bitpanda", family: @item.family))
    Security.any_instance.stubs(:find_or_fetch_price).returns(nil)
    assert_no_difference [ "Account.count", "BitpandaAccount.count", "Entry.count", "Holding.count" ] do
      assert_raises(Provider::Bitpanda::InvalidDataError) { syncer.perform_sync(@sync) }
    end
  end

  test "empty complete portfolio closes absent provider holdings" do
    syncer.perform_sync(@sync)
    @snapshot["portfolio"] = []
    syncer.perform_sync(@sync)
    account = @item.accounts.sole
    assert_equal 0, account.balance
    assert_equal 0, account.holdings.where(date: Date.current).sole.qty
  end

  test "user edited trades and transactions remain protected" do
    syncer.perform_sync(@sync)
    entries = @item.accounts.sole.entries.where(source: "bitpanda")
    entries.each { |entry| entry.update!(name: "My custom name", user_modified: true) }
    @snapshot["operations"].last["transactions"].last["asset_amount"]["value"] = "550"
    syncer.perform_sync(@sync)
    assert_equal [ "My custom name" ], entries.reload.pluck(:name).uniq
    assert_equal 500, entries.find_by!(external_id: "bitpanda_buy-btc").amount
  end

  test "authentication failures request a new key and record family scoped diagnostics" do
    @provider.stubs(:snapshot).raises(Provider::Bitpanda::AuthenticationError, "Read access denied")
    DebugLogEntry.expects(:capture).with(has_entries(provider_key: "bitpanda", family: @item.family))
    assert_raises(Provider::Bitpanda::AuthenticationError) { syncer.perform_sync(@sync) }
    assert @item.reload.requires_update?
  end

  test "connections scheduled for deletion never fetch data" do
    @item.update!(scheduled_for_deletion: true)
    @provider.expects(:snapshot).never
    syncer.perform_sync(@sync)
  end

  test "disconnect preserves imported canonical accounts entries and holdings" do
    syncer.perform_sync(@sync)
    account = @item.accounts.sole
    entries = account.entries.count
    holdings = account.holdings.count
    @item.destroy!
    assert_equal entries, account.reload.entries.count
    assert_equal holdings, account.holdings.count
    assert_empty account.account_providers
    assert_nil account.holdings.sole.account_provider_id
  end

  test "legacy fiat counterpart is excluded once without deleting its audit history" do
    syncer.perform_sync(@sync)
    account = @item.accounts.sole
    legacy = account.entries.create!(name: "Legacy fiat leg", source: "bitpanda", external_id: "bitpanda_buy-eur",
      date: Date.new(2026, 10, 22), amount: 500, currency: "EUR", entryable: Transaction.new(kind: "funds_movement"))
    @snapshot["operations"].last["transactions"].first["trade"].merge!("rate_with_fee" => "50000.12345678", "fee" => { "value" => "1" })
    DebugLogEntry.expects(:capture).with(has_entries(provider_key: "bitpanda", level: "warn")).once
    2.times { syncer.perform_sync(@sync) }
    assert legacy.reload.excluded?
    assert_equal 500, legacy.amount
    trade = account.entries.find_by!(external_id: "bitpanda_buy-btc")
    assert_equal BigDecimal("50000.12345678"), trade.trade.price
    assert_equal 1, trade.trade.fee
    assert_equal Time.utc(2026, 10, 22, 12), trade.occurred_at
    assert_equal 2, account.entries.where(source: "bitpanda", excluded: false).count
  end

  test "edited fiat counterparts prevent silent double cash accounting and remain untouched" do
    syncer.perform_sync(@sync)
    account = @item.accounts.sole
    legacy = account.entries.create!(name: "My edited fiat leg", source: "bitpanda", external_id: "bitpanda_buy-eur",
      date: Date.new(2026, 10, 22), amount: 501, currency: "EUR", user_modified: true,
      entryable: Transaction.new(kind: "funds_movement"))
    DebugLogEntry.stubs(:capture)
    assert_raises(Provider::Bitpanda::InvalidDataError) { syncer.perform_sync(@sync) }
    assert_not legacy.reload.excluded?
    assert_equal 501, legacy.amount
    assert_equal "My edited fiat leg", legacy.name
  end

  private

    def syncer
      BitpandaItem::Syncer.new(@item)
    end
end
