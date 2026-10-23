require "test_helper"

class CryptoActivitiesControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    @account = families(:dylan_family).accounts.create!(name: "Manual crypto", currency: "EUR", balance: 0, accountable: Crypto.new(subtype: "wallet"))
    Account.any_instance.stubs(:sync_later)
  end

  test "renders datetime and manual price fields for crypto wallets" do
    get new_crypto_activity_url(account_id: @account.id)
    assert_response :success
    assert_select "input[type=datetime-local][name='crypto_activity[occurred_at]']"
    assert_select "input[name='crypto_activity[unit_price_eur]']"
    assert_select "input[name='crypto_activity[fee_eur]']"
  end

  test "creates a timestamped manual crypto purchase without overwriting its given price" do
    Crypto::HistoricalQuote.expects(:fetch).never
    post crypto_activities_url(account_id: @account.id), params: { crypto_activity: {
      description: "BTC bought elsewhere", kind: "buy", symbol: "BTC", quantity: "0.01",
      unit_price_eur: "100000", fee_eur: "1", occurred_at: "2025-07-23T12:34", time_zone: "UTC"
    } }
    assert_redirected_to account_path(@account)
    entry = @account.entries.where(source: "manual_crypto").sole
    assert_equal 100000, entry.trade.price
    assert_equal Time.utc(2025, 7, 23, 12, 34), entry.occurred_at
  end

  test "serves timestamped EUR quote suggestions to writable manual accounts only" do
    quote = Provider::BinancePublic::IntradayPrice.new(price: BigDecimal("100000"), currency: "EUR",
      requested_at: Time.utc(2025, 7, 23, 12, 34), quoted_at: Time.utc(2025, 7, 23, 12, 34), source: "binance_public_1m_open")
    Crypto::HistoricalQuote.expects(:fetch).with(symbol: "BTC", at: Time.utc(2025, 7, 23, 12, 34)).returns(quote)
    get quote_crypto_activities_url(account_id: @account.id, symbol: "BTC", occurred_at: "2025-07-23T12:34", time_zone: "UTC"), as: :json
    assert_response :success
    assert_equal "100000.0", response.parsed_body["price"]
    assert_equal "EUR", response.parsed_body["currency"]
    sign_in users(:family_member)
    Crypto::HistoricalQuote.expects(:fetch).never
    get quote_crypto_activities_url(account_id: @account.id, symbol: "BTC", occurred_at: "2025-07-23T12:34"), as: :json
    assert_includes [ 403, 404 ], response.status
  end

  test "cannot access another family's manual account" do
    other = families(:empty).accounts.create!(name: "Private", currency: "EUR", balance: 0, accountable: Crypto.new(subtype: "wallet"))
    get new_crypto_activity_url(account_id: other.id)
    assert_response :not_found
  end

  test "crypto portfolio reuses the grouped activity feed and opens its rows in the drawer" do
    form = Crypto::ActivityForm.new(account: @account, description: "My timestamped buy", symbol: "BTC",
      quantity: "0.01", unit_price_eur: "100000", occurred_at: "2025-07-23T12:34")
    assert form.save
    get account_url(@account)
    assert_response :success
    assert_select "a[href=?]", new_crypto_activity_path(account_id: @account.id)
    assert_select "form#entries-search"
    assert_select "[data-controller=bulk-select]"
    assert_select "[data-bulk-select-target=group] summary", text: /#{I18n.l(form.entry.date, format: :long)}/
    assert_select "a[href=?][data-turbo-frame=drawer]", entry_path(form.entry), text: "My timestamped buy"
    assert_select "p", text: "+0.01 BTC"
    assert_select "p", text: /12:34:00/
    assert_select "[data-bulk-select-target=row][data-id=?]", form.entry.id
    assert_select "table", count: 0
  end

  test "manual trade drawer shows native valuation fees and running balance using standard sections" do
    form = Crypto::ActivityForm.new(account: @account, description: "My timestamped buy", symbol: "BTC",
      quantity: "0.01", unit_price_eur: "100000", fee_eur: "1", occurred_at: "2025-07-23T12:34")
    assert form.save
    get trade_url(form.entry), headers: { "Turbo-Frame" => "drawer" }
    assert_response :success
    assert_select "turbo-frame#drawer"
    assert_select "input[name='crypto_movement[description]'][value='My timestamped buy']"
    assert_select "input[name='crypto_movement[quantity]'][value='+0.01 BTC']"
    assert_select "input.form-field__input[name^='crypto_movement']", count: 5
    assert_select "dt", text: I18n.t("crypto_ledger.unit_price_eur")
    assert_select "dt", text: I18n.t("crypto_ledger.fees")
    assert_select "dd", text: "0.01 BTC"
    assert_select "textarea[name='entry[notes]']"
    assert_select "input[name='entry[excluded]']"
    assert_select "input[name='entry[entryable_attributes][price]']", count: 0
  end

  test "fiat crypto movements use the same transaction drawer with crypto details and attachments" do
    form = Crypto::ActivityForm.new(account: @account, description: "Deposit EUR", kind: "deposit", symbol: "EUR",
      quantity: "500", occurred_at: "2025-07-23T12:34")
    assert form.save
    get transaction_url(form.entry), headers: { "Turbo-Frame" => "drawer" }
    assert_response :success
    assert_select "turbo-frame#drawer"
    assert_select "input[name='crypto_movement[description]'][value='Deposit EUR']"
    assert_select "input[name='crypto_movement[quantity]'][value='+500 EUR']"
    assert_select "dd", text: "500 EUR"
    assert_select "input[name='entry[amount]']", count: 0
    assert_select "summary", text: /#{I18n.t('transactions.show.attachments')}/
  end

  test "linked crypto drawer uses original native values instead of its zero cash effect" do
    item = bitpanda_items(:one)
    snapshot = JSON.parse(file_fixture("bitpanda/snapshot.json").read)
    snapshot["operations"] = [ { "operation_id" => "deposit", "operation_type" => "deposit", "transactions" => [ {
      "transaction_id" => "deposit-btc", "asset_id" => "btc", "asset_amount" => { "value" => "0.01" },
      "flow" => "INCOMING", "credited_at" => "2026-10-22T12:00:00Z", "asset_balance_after" => { "value" => "0.01" }
    } ] } ]
    item.stubs(:provider).returns(stub(snapshot: snapshot))
    Security.stubs(:search_provider).returns([])
    BitpandaItem::Syncer.new(item).perform_sync(item.syncs.create!)
    entry = item.accounts.sole.entries.where(source: "bitpanda").sole
    assert entry.amount.zero?
    get trade_url(entry), headers: { "Turbo-Frame" => "drawer" }
    assert_response :success
    assert_select "h3", text: /\+0.01 BTC/
    assert_select "input[name='crypto_movement[value_eur]'][value=?]", I18n.t("crypto_ledger.not_provided")
    assert_select "dd", text: "0.01 BTC"
    assert_select "input[name='entry[amount]']", count: 0
  end
end
