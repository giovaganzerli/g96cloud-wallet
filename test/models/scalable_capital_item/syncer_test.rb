require "test_helper"

class ScalableCapitalItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @item = scalable_capital_items(:one)
    @sync = @item.syncs.create!
    @snapshot = {
      "date" => "2026-10-21",
      "overview" => { "account_id" => "sc-account", "portfolio_id" => "sc-portfolio" },
      "cash" => { "cash_balance" => "100.25" },
      "holdings" => [ {
        "isin" => "IE00B4L5Y983", "name" => "World ETF", "quantity" => "1.25",
        "valuation" => "125.5", "valuation_currency" => "EUR", "quote_currency" => "EUR", "fifo_price" => "80"
      } ],
      "transactions" => [ {
        "id" => "deposit-1", "summary_type" => "BrokerCashTransactionSummary",
        "status" => "SETTLED", "description" => "Deposit", "currency" => "EUR",
        "is_cancellation" => false, "last_event_datetime" => "2026-10-20T12:00:00Z",
        "cash_transaction_type" => "DEPOSIT", "amount" => "100"
      } ]
    }
    provider = mock
    provider.stubs(:snapshot).returns(@snapshot)
    @item.stubs(:provider).returns(provider)
    Account.any_instance.stubs(:sync_later)
  end

  test "repeated imports keep one account one holding and one transaction" do
    syncer = ScalableCapitalItem::Syncer.new(@item)
    2.times { syncer.perform_sync(@sync) }

    assert_equal 1, @item.scalable_capital_accounts.count
    account = @item.accounts.sole
    assert_equal "Investment", account.accountable_type
    assert_equal BigDecimal("225.75"), account.balance
    assert_equal BigDecimal("100.25"), account.cash_balance
    assert_equal 1, account.holdings.where(account_provider: @item.scalable_capital_accounts.sole.account_provider).count
    assert_equal 1, account.entries.where(source: "scalable_capital").count
    assert_equal BigDecimal("-100"), account.entries.where(source: "scalable_capital").sole.amount
    assert @item.reload.good?
  end

  test "invalid snapshot rolls back account creation and financial records" do
    @snapshot["cash"]["cash_balance"] = nil
    assert_no_difference [ "Account.count", "ScalableCapitalAccount.count", "Entry.count", "Holding.count" ] do
      assert_raises(Provider::ScalableCapital::InvalidDataError) { ScalableCapitalItem::Syncer.new(@item).perform_sync(@sync) }
    end
  end

  test "an empty complete snapshot closes previously held securities" do
    syncer = ScalableCapitalItem::Syncer.new(@item)
    syncer.perform_sync(@sync)
    @snapshot["date"] = "2026-10-22"
    @snapshot["holdings"] = []
    syncer.perform_sync(@sync)
    account = @item.accounts.sole
    assert_equal BigDecimal("100.25"), account.balance
    assert_equal 0, account.holdings.where(date: "2026-10-22").sole.qty
  end

  test "reauthorization failure marks the item and records diagnostics" do
    provider = mock
    provider.expects(:snapshot).raises(Provider::ScalableCapital::AuthenticationError, "Authorization required")
    @item.stubs(:provider).returns(provider)
    DebugLogEntry.expects(:capture).with(has_entries(provider_key: "scalable_capital", family: @item.family))
    assert_raises(Provider::ScalableCapital::AuthenticationError) { ScalableCapitalItem::Syncer.new(@item).perform_sync(@sync) }
    assert @item.reload.requires_update?
  end

  test "modified trades remain protected on subsequent imports" do
    syncer = ScalableCapitalItem::Syncer.new(@item)
    syncer.perform_sync(@sync)
    account = @item.accounts.sole
    entry = Account::ProviderImportAdapter.new(account).import_trade(
      security: account.holdings.sole.security, quantity: 1, price: 99, amount: 99, currency: "EUR", date: "2026-10-20",
      external_id: "scalable_capital_trade-1", source: "scalable_capital"
    )
    entry.update!(user_modified: true, name: "My edited trade")
    @snapshot["transactions"] << {
      "id" => "trade-1", "summary_type" => "BrokerSecurityTransactionSummary",
      "status" => "FILLED", "description" => "Broker trade", "currency" => "EUR",
      "is_cancellation" => false, "last_event_datetime" => "2026-10-20T12:00:00Z",
      "details" => {
        "id" => "trade-1", "currency" => "EUR", "detail_type" => "security_trade",
        "last_event_datetime" => "2026-10-20T12:00:00Z", "is_pending" => false,
        "security" => { "isin" => "IE00B4L5Y983" },
        "security_trade" => { "side" => "BUY", "number_of_shares" => { "filled" => "1" }, "average_price" => "100", "total_amount" => "101" }
      }
    }
    syncer.perform_sync(@sync)
    assert_equal "My edited trade", entry.reload.name
    assert_equal 99, entry.amount
  end
end
