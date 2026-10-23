require "test_helper"

class Crypto::ActivityFormTest < ActiveSupport::TestCase
  setup do
    @account = families(:dylan_family).accounts.create!(name: "Manual crypto", currency: "EUR", balance: 0, cash_balance: 0, accountable: Crypto.new(subtype: "wallet"))
    Account.any_instance.stubs(:sync_later)
    @attributes = { account: @account, description: "My BTC purchase", kind: "buy", symbol: "BTC",
      quantity: "0.001", occurred_at: "2025-07-23T12:34:56", time_zone: "UTC", fee_eur: "1" }
  end

  test "manual prices win and externally funded wallets have no invented EUR cash debit" do
    Crypto::HistoricalQuote.expects(:fetch).never
    form = Crypto::ActivityForm.new(@attributes.merge(unit_price_eur: "105338.57729381"))
    assert form.save, form.errors.full_messages.to_sentence
    entry = form.entry.reload
    assert_equal "My BTC purchase", entry.name
    assert_equal Time.utc(2025, 7, 23, 12, 34, 56), entry.occurred_at
    assert_equal BigDecimal("105338.57729381"), entry.trade.price
    assert_equal 1, entry.trade.fee
    assert_equal 0, entry.amount
    assert_equal "105.33857729381", entry.trade.extra.dig("crypto", "value_eur")
    assert_equal "manual", entry.trade.extra.dig("crypto", "price_source")
  end

  test "an explicitly entered EUR value derives the unit price without a network call" do
    Crypto::HistoricalQuote.expects(:fetch).never
    form = Crypto::ActivityForm.new(@attributes.merge(value_eur: "100"))
    assert form.save
    assert_equal 100_000, form.entry.trade.price
  end

  test "empty price and value request a timestamped market quote" do
    quote = Provider::BinancePublic::IntradayPrice.new(price: BigDecimal("100000"), currency: "EUR",
      requested_at: Time.utc(2025, 7, 23, 12, 34, 56), quoted_at: Time.utc(2025, 7, 23, 12, 34), source: "binance_public_1m_open")
    Crypto::HistoricalQuote.expects(:fetch).with(symbol: "BTC", at: Time.utc(2025, 7, 23, 12, 34, 56)).returns(quote)
    form = Crypto::ActivityForm.new(@attributes)
    assert form.save
    assert_equal "binance_public_1m_open", form.entry.trade.extra.dig("crypto", "price_source")
    assert_equal "2025-07-23T12:34:00Z", form.entry.trade.extra.dig("crypto", "quoted_at")
  end

  test "wallet funding changes only the explicitly chosen EUR cash balance" do
    form = Crypto::ActivityForm.new(@attributes.merge(unit_price_eur: "100000", funded_from_wallet: "1"))
    assert form.save
    assert_equal 101, form.entry.amount
    assert_equal "-101.0", form.entry.trade.extra.dig("crypto", "cash_delta_eur")
  end

  test "accepted autofill retains the market source and minute rather than claiming an execution price" do
    quote = Provider::BinancePublic::IntradayPrice.new(price: BigDecimal("100000"), currency: "EUR",
      requested_at: Time.utc(2025, 7, 23, 12, 34, 56), quoted_at: Time.utc(2025, 7, 23, 12, 34), source: "binance_public_1m_open")
    Crypto::HistoricalQuote.expects(:fetch).returns(quote)
    form = Crypto::ActivityForm.new(@attributes.merge(unit_price_eur: "100000", value_eur: "100", suggested_price: "true"))
    assert form.save
    assert_equal "binance_public_1m_open", form.entry.trade.extra.dig("crypto", "price_source")
    assert_equal "2025-07-23T12:34:00Z", form.entry.trade.extra.dig("crypto", "quoted_at")
  end

  test "sales carry negative native quantity positive proceeds and a fee" do
    form = Crypto::ActivityForm.new(@attributes.merge(kind: "sell", unit_price_eur: "100000", funded_from_wallet: true))
    assert form.save
    assert_equal BigDecimal("-0.001"), form.entry.trade.qty
    assert_equal(-99, form.entry.amount)
    assert_equal "Sell", form.entry.trade.investment_activity_label
  end

  test "swap creates two native movements without inventing a fiat exchange" do
    form = Crypto::ActivityForm.new(@attributes.merge(kind: "swap", quantity: "0.1", unit_price_eur: "100000", counter_symbol: "ETH", counter_quantity: "5"))
    assert_difference "@account.entries.where(source: 'manual_crypto').count", 2 do
      assert form.save
    end
    entries = @account.entries.where(source: "manual_crypto").includes(:entryable)
    assert_equal [ BigDecimal("-0.1"), BigDecimal("5") ], entries.map { |entry| entry.trade.qty }.sort
    assert entries.all? { |entry| entry.amount.zero? }
    assert entries.all? { |entry| entry.trade.investment_activity_label == "Exchange" }
  end

  test "EUR deposits need no market quote and preserve exact time in the selected zone" do
    Crypto::HistoricalQuote.expects(:fetch).never
    form = Crypto::ActivityForm.new(@attributes.merge(kind: "deposit", symbol: "EUR", quantity: "500", fee_eur: "0", time_zone: "Europe/Rome"))
    assert form.save
    assert form.entry.transaction?
    assert_equal(-500, form.entry.amount)
    assert_equal Time.utc(2025, 7, 23, 10, 34, 56), form.entry.occurred_at
  end

  test "unavailable quotes and invalid manual inputs never create partial movements" do
    Crypto::HistoricalQuote.stubs(:fetch).raises(Crypto::HistoricalQuote::UnavailableError, "Missing quote")
    assert_no_difference "@account.entries.count" do
      assert_not Crypto::ActivityForm.new(@attributes).save
      assert_not Crypto::ActivityForm.new(@attributes.merge(unit_price_eur: "NaN")).save
      assert_not Crypto::ActivityForm.new(@attributes.merge(quantity: "-1")).save
      assert_not Crypto::ActivityForm.new(@attributes.merge(time_zone: nil)).save
      assert_not Crypto::ActivityForm.new(@attributes.merge(kind: "deposit", symbol: "EUR", value_eur: "100")).save
      assert_not Crypto::ActivityForm.new(@attributes.merge(unit_price_eur: "100", value_eur: "999")).save
    end
  end
end
