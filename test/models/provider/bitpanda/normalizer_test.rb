require "test_helper"

class Provider::Bitpanda::NormalizerTest < ActiveSupport::TestCase
  setup do
    @snapshot = JSON.parse(file_fixture("bitpanda/snapshot.json").read)
  end

  test "normalizes exact decimals and EUR portfolio valuations" do
    positions = normalizer.positions
    assert_equal BigDecimal("0.01"), positions.first[:quantity]
    assert_equal BigDecimal("600"), positions.first[:amount]
    assert positions.first[:asset]
    assert_not positions.last[:asset]
    assert_equal Date.new(2026, 10, 23), normalizer.date
  end

  test "EUR fiat wallets do not require an equivalent currency balance" do
    @snapshot["portfolio"].last.delete("currency_balance")
    ExchangeRate.expects(:find_or_fetch_rate).never

    position = normalizer.positions.last
    assert_not position[:asset]
    assert_equal BigDecimal("100"), position[:quantity]
    assert_equal BigDecimal("100"), position[:amount]
  end

  test "foreign fiat wallets without currency balance use an exact date FX rate" do
    @snapshot["currencies"] << { "id" => "usd", "symbol" => "USD", "name" => "US Dollar" }
    @snapshot["portfolio"] << { "currency_id" => "usd", "balance" => { "value" => "12.50", "currency_id" => "usd" } }
    ExchangeRate.expects(:find_or_fetch_rate).with(from: "USD", to: "EUR", date: Date.new(2026, 10, 23))
      .returns(OpenStruct.new(date: Date.new(2026, 10, 23), rate: BigDecimal("0.9")))

    assert_equal BigDecimal("11.25"), normalizer.positions.last[:amount]
  end

  test "missing or stale FX rates do not silently value foreign fiat at zero" do
    @snapshot["currencies"] << { "id" => "usd", "symbol" => "USD", "name" => "US Dollar" }
    @snapshot["portfolio"] << { "currency_id" => "usd", "balance" => { "value" => "12.50", "currency_id" => "usd" } }
    [ nil, OpenStruct.new(date: Date.new(2026, 10, 22), rate: BigDecimal("0.9")),
      OpenStruct.new(date: Date.new(2026, 10, 23), rate: 0) ].each do |rate|
      ExchangeRate.stubs(:find_or_fetch_rate).returns(rate)
      assert_raises(Provider::Bitpanda::InvalidDataError) { normalizer.positions }
    end
  end

  test "a missing asset valuation still fails instead of treating quantity as EUR" do
    @snapshot["portfolio"].first.delete("currency_balance")
    assert_raises(Provider::Bitpanda::InvalidDataError) { normalizer.positions }
  end

  test "imports a fiat trade once with correct signs and retains both raw legs" do
    activities = normalizer.activities
    assert_equal 2, activities.size
    deposit, buy = activities
    assert_equal BigDecimal("-600"), deposit[:amount]
    assert_equal "Transfer", deposit[:label]
    assert_equal BigDecimal("0.01"), buy[:quantity]
    assert_equal BigDecimal("500"), buy[:amount]
    assert_equal BigDecimal("50000"), buy[:price]
    assert_equal "Buy", buy[:label]
    assert_equal 2, buy[:metadata]["operation_transactions"].size
  end

  test "ordinary operations can omit the per transaction subtype" do
    @snapshot["operations"].each do |operation|
      operation["transactions"].each { |row| row.delete("transaction_type") }
    end
    assert_equal [ "Transfer", "Buy" ], normalizer.activities.pluck(:label)
    assert_equal BigDecimal("500"), normalizer.activities.last[:amount]
  end

  test "missing transaction subtype does not silently accept unknown operations" do
    operation = @snapshot["operations"].first
    operation["operation_type"] = "unknown_adjustment"
    operation["transactions"].first.delete("transaction_type")
    assert_raises(Provider::Bitpanda::InvalidDataError) { normalizer.activities }
  end

  test "sale reduces quantity and increases cash" do
    rows = @snapshot["operations"].last["transactions"]
    rows.first["flow"] = "OUTGOING"
    rows.last["flow"] = "INCOMING"
    sell = normalizer.activities.last
    assert_equal BigDecimal("-0.01"), sell[:quantity]
    assert_equal BigDecimal("-500"), sell[:amount]
    assert_equal "Sell", sell[:label]
  end

  test "asset transfers are cash neutral with unknown cost basis" do
    @snapshot["operations"] = [ { "operation_id" => "transfer", "operation_type" => "DEPOSIT", "transactions" => [
      { "transaction_id" => "btc-deposit", "asset_id" => "btc", "asset_amount" => { "value" => "0.1" },
        "transaction_type" => "DEPOSIT", "flow" => "INCOMING", "credited_at" => "2026-10-22T12:00:00Z" }
    ] } ]
    transfer = normalizer.activities.sole
    assert_equal "Transfer", transfer[:label]
    assert_equal 0, transfer[:amount]
    assert_nil transfer[:price]
  end

  test "reclaim and refund preserve quantity and direction as corrections requiring review" do
    %w[reclaim refund].each do |type|
      %w[INCOMING OUTGOING].each do |flow|
        @snapshot["operations"] = [ { "operation_id" => "correction", "operation_type" => type, "transactions" => [
          { "transaction_id" => "corrected-btc", "asset_id" => "btc", "asset_amount" => { "value" => "0.001" },
            "flow" => flow, "credited_at" => "2026-10-22T12:00:00Z", "compensates" => "original-transaction" }
        ] } ]
        correction = normalizer.activities.sole
        assert_equal "Transfer", correction[:label]
        assert_equal BigDecimal(flow == "INCOMING" ? "0.001" : "-0.001"), correction[:quantity]
        assert_equal 0, correction[:amount]
        assert_nil correction[:price]
        assert correction[:metadata]["review_required"]
        assert_equal "original-transaction", correction[:metadata]["transaction"]["compensates"]
      end
    end
  end

  test "fiat refunds retain their cash effect without becoming income" do
    @snapshot["operations"] = [ @snapshot["operations"].first ]
    @snapshot["operations"].first["operation_type"] = "refund"
    @snapshot["operations"].first["transactions"].first.delete("transaction_type")
    correction = normalizer.activities.sole
    assert_equal "Transfer", correction[:label]
    assert_equal BigDecimal("-600"), correction[:amount]
    assert correction[:metadata]["review_required"]
  end

  test "missing values invalid decimals and wrong valuation currencies never become zero" do
    [ nil, "not-a-number", "NaN", "Infinity" ].each do |value|
      snapshot = @snapshot.deep_dup
      snapshot["portfolio"].first["balance"]["value"] = value
      assert_raises(Provider::Bitpanda::InvalidDataError) { normalizer(snapshot).positions }
    end
    @snapshot["portfolio"].first["currency_balance"]["currency_id"] = "usd"
    assert_raises(Provider::Bitpanda::InvalidDataError) { normalizer.positions }
  end

  test "unknown asset identifiers duplicate positions and unsupported operations fail explicitly" do
    snapshot = @snapshot.deep_dup
    snapshot["portfolio"].first["asset_id"] = "unknown"
    assert_raises(Provider::Bitpanda::InvalidDataError) { normalizer(snapshot).positions }
    snapshot = @snapshot.deep_dup
    snapshot["portfolio"] << snapshot["portfolio"].first
    assert_raises(Provider::Bitpanda::InvalidDataError) { normalizer(snapshot).positions }
    @snapshot["operations"].first["operation_type"] = "UNKNOWN"
    @snapshot["operations"].first["transactions"].first["transaction_type"] = "UNKNOWN"
    assert_raises(Provider::Bitpanda::InvalidDataError) { normalizer.activities }
  end

  test "unknown directions and mismatched trade directions fail explicitly" do
    @snapshot["operations"].last["transactions"].first["flow"] = "SIDEWAYS"
    assert_raises(Provider::Bitpanda::InvalidDataError) { normalizer.activities }
    @snapshot["operations"].last["transactions"].first["flow"] = "OUTGOING"
    assert_raises(Provider::Bitpanda::InvalidDataError) { normalizer.activities }
  end

  test "amounts cannot refer to another asset" do
    @snapshot["portfolio"].first["balance"]["asset_id"] = "eth"
    assert_raises(Provider::Bitpanda::InvalidDataError) { normalizer.positions }
    @snapshot["operations"].last["transactions"].first["asset_amount"]["asset_id"] = "eth"
    assert_raises(Provider::Bitpanda::InvalidDataError) { normalizer.activities }
  end

  test "staking allocations and unstaking are transfers rather than income" do
    @snapshot["operations"] = [ @snapshot["operations"].first ]
    %w[STAKING UNSTAKING STAKE UNSTAKE].each do |type|
      operation = @snapshot["operations"].first
      operation["operation_type"] = type
      operation["transactions"].first["transaction_type"] = type
      assert_equal "Transfer", normalizer.activities.sole[:label]
    end
    @snapshot["operations"].first["transactions"].first["transaction_type"] = "STAKING_REWARD"
    assert_equal "Dividend", normalizer.activities.sole[:label]
  end

  test "swap matches each asset to its own trade quote and preserves execution rates and fees" do
    @snapshot["assets"] << { "id" => "eth", "symbol" => "ETH", "name" => "Ethereum", "type" => "cryptocoin" }
    outgoing, outgoing_cash = @snapshot["operations"].last["transactions"].deep_dup
    outgoing["flow"] = "OUTGOING"
    outgoing["trade"].merge!("rate_with_fee" => "49999.12345678", "fee" => { "value" => "1" })
    outgoing_cash["flow"] = "INCOMING"
    incoming = outgoing.deep_dup
    incoming.merge!("transaction_id" => "receive-eth", "asset_id" => "eth", "asset_amount" => { "value" => "0.2", "asset_id" => "eth" }, "flow" => "INCOMING")
    incoming["trade"] = { "trade_id" => "trade-2", "rate_with_fee" => "2500.25", "fee" => { "value" => "2" } }
    incoming_cash = outgoing_cash.deep_dup
    incoming_cash.merge!("transaction_id" => "spend-eur", "flow" => "OUTGOING", "trade" => { "trade_id" => "trade-2" })
    @snapshot["operations"] = [ { "operation_id" => "swap", "operation_type" => "swap", "transactions" => [ outgoing, incoming_cash, incoming, outgoing_cash ] } ]

    spent, received = normalizer.activities
    assert_equal 2, normalizer.activities.size
    assert_equal [ "Exchange", "Exchange" ], [ spent[:label], received[:label] ]
    assert_equal BigDecimal("-0.01"), spent[:quantity]
    assert_equal BigDecimal("0.2"), received[:quantity]
    assert_equal BigDecimal("49999.12345678"), spent[:price]
    assert_equal BigDecimal("2500.25"), received[:price]
    assert_equal [ 1, 2 ], [ spent[:fee], received[:fee] ]
    assert_equal 0, spent[:amount] + received[:amount]
    assert_equal [ "buy-eur", "spend-eur" ], [ spent[:metadata]["cash_transaction_id"], received[:metadata]["cash_transaction_id"] ]
  end

  private

    def normalizer(snapshot = @snapshot)
      Provider::Bitpanda::Normalizer.new(snapshot)
    end
end
