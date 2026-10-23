require "test_helper"
require "ostruct"

class Security::PriceTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @provider = mock
    @security = securities(:aapl)
    @security.stubs(:price_data_provider).returns(@provider)
  end

  test "finds single security price in DB" do
    @provider.expects(:fetch_security_price).never
    price = security_prices(:one)

    assert_equal price, @security.find_or_fetch_price(date: price.date)
  end

  test "caches prices from provider to DB" do
    price_date = 10.days.ago.to_date

    expected_price = Security::Price.new(
      security: @security,
      date: price_date,
      price: 314.34,
      currency: "USD"
    )

    expect_provider_price(security: @security, price: expected_price, date: price_date)

    assert_difference "Security::Price.count", 1 do
      fetched_price = @security.find_or_fetch_price(date: price_date, cache: true)
      assert_equal expected_price.price, fetched_price.price
    end
  end

  test "reuses a price inserted while the provider request is in flight" do
    price_date = 30.years.ago.to_date
    existing_price = Security::Price.create!(
      security: @security,
      date: price_date,
      price: 300,
      currency: "USD"
    )
    provider_price = Security::Price.new(
      security: @security,
      date: price_date,
      price: 314.34,
      currency: "USD"
    )

    # Simulate the initial lookup losing a race to another price insert.
    @security.prices.expects(:find_by).with(date: price_date).returns(nil)
    expect_provider_price(security: @security, price: provider_price, date: price_date)

    assert_no_difference "Security::Price.count" do
      fetched_price = @security.find_or_fetch_price(date: price_date, cache: true)
      assert_equal provider_price.price, fetched_price.price
    end
    assert_equal 300, existing_price.reload.price
  end

  test "returns nil if no price found in DB or from provider" do
    security = securities(:aapl)
    Security::Price.delete_all # Clear any existing prices

    with_provider_response = provider_error_response(StandardError.new("Test error"))

    @provider.expects(:fetch_security_price)
             .with(symbol: security.ticker, exchange_operating_mic: security.exchange_operating_mic, date: Date.current)
             .returns(with_provider_response)

    assert_not @security.find_or_fetch_price(date: Date.current)
  end

  test "persists sub-cent crypto prices without rounding them to zero" do
    price = BigDecimal("0.000000123456789012")
    record = @security.prices.create!(date: Date.new(2025, 7, 23), price: price, currency: "EUR")
    assert_equal price, record.reload.price
  end

  test "repairs a rounded zero crypto cache from the exact date provider quote" do
    @security.update!(ticker: "PEPEEUR", exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC)
    date = Date.new(2025, 7, 23)
    cached = @security.prices.create!(date: date, price: 0, currency: "EUR")
    quote = OpenStruct.new(date: date, price: BigDecimal("0.000012345678901234"), currency: "EUR")
    expect_provider_price(security: @security, price: quote, date: date)

    assert_no_difference "Security::Price.count" do
      assert_equal quote.price, @security.find_or_fetch_price(date: date).price
    end
    assert_equal quote.price, cached.reload.price
  end

  test "cache false fetches a valid crypto quote without modifying the zero cache" do
    @security.update!(ticker: "PEPEEUR", exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC)
    date = Date.new(2025, 7, 23)
    cached = @security.prices.create!(date: date, price: 0, currency: "EUR")
    quote = OpenStruct.new(date: date, price: BigDecimal("0.00001234"), currency: "EUR")
    expect_provider_price(security: @security, price: quote, date: date)

    assert_equal quote.price, @security.find_or_fetch_price(date: date, cache: false).price
    assert_equal 0, cached.reload.price
  end

  test "zero crypto caches are not replaced by wrong date currency or nonpositive quotes" do
    @security.update!(ticker: "PEPEEUR", exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC)
    date = Date.new(2025, 7, 23)
    cached = @security.prices.create!(date: date, price: 0, currency: "EUR")
    [ OpenStruct.new(date: date.prev_day, price: BigDecimal("0.00001"), currency: "EUR"),
      OpenStruct.new(date: date, price: BigDecimal("0.00001"), currency: "USD"),
      OpenStruct.new(date: date, price: BigDecimal("Infinity"), currency: "EUR"),
      OpenStruct.new(date: date, price: BigDecimal("NaN"), currency: "EUR"),
      OpenStruct.new(date: date, price: 0, currency: "EUR") ].each do |quote|
      expect_provider_price(security: @security, price: quote, date: date)
      assert_equal cached.id, @security.find_or_fetch_price(date: date).id
      assert_equal 0, cached.reload.price
    end
  end

  test "a zero crypto cache survives an upstream error without replacement" do
    @security.update!(ticker: "PEPEEUR", exchange_operating_mic: Provider::BinancePublic::BINANCE_MIC)
    date = Date.new(2025, 7, 23)
    cached = @security.prices.create!(date: date, price: 0, currency: "EUR")
    @provider.expects(:fetch_security_price).returns(provider_error_response(Provider::Error.new("Unavailable")))

    assert_equal cached, @security.find_or_fetch_price(date: date)
    assert_equal 0, cached.reload.price
  end

  test "zero non crypto cache entries are not automatically overwritten" do
    date = Date.new(2025, 7, 23)
    cached = @security.prices.create!(date: date, price: 0, currency: "USD")
    @provider.expects(:fetch_security_price).never
    assert_equal cached, @security.find_or_fetch_price(date: date)
  end

  private
    def expect_provider_price(security:, price:, date:)
      @provider.expects(:fetch_security_price)
               .with(symbol: security.ticker, exchange_operating_mic: security.exchange_operating_mic, date: date)
               .returns(provider_success_response(price))
    end

    def expect_provider_prices(security:, prices:, start_date:, end_date:)
      @provider.expects(:fetch_security_prices)
               .with(security, start_date: start_date, end_date: end_date)
               .returns(provider_success_response(prices))
    end
end
