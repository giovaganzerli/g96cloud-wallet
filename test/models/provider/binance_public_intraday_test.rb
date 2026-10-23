require "test_helper"

class Provider::BinancePublicIntradayTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::BinancePublic.new
    @provider.stubs(:throttle_request)
    @at = Time.utc(2025, 7, 23, 12, 34, 56)
    @minute = Time.utc(2025, 7, 23, 12, 34)
    @url = "https://data-api.binance.vision/api/v3/klines"
  end

  test "uses the opening price from the exact UTC minute in EUR" do
    request = stub_quote([ [ @minute.to_i * 1000, "105338.57729381", "999999", "1", "888888" ] ])
    response = @provider.fetch_security_price_at(symbol: "CRYPTO:BTCEUR", timestamp: @at)
    assert response.success?
    assert_equal BigDecimal("105338.57729381"), response.data.price
    assert_equal "EUR", response.data.currency
    assert_equal @minute, response.data.quoted_at
    assert_equal @at, response.data.requested_at
    assert_requested request
  end

  test "missing stale zero and nonfinite quotes are errors not spot fallbacks" do
    [ [], [ [ @minute.to_i * 1000 - 60_000, "123" ] ],
      [ [ @minute.to_i * 1000, "0" ] ], [ [ @minute.to_i * 1000, "NaN" ] ] ].each do |rows|
      stub_quote(rows)
      response = @provider.fetch_security_price_at(symbol: "CRYPTO:BTCEUR", timestamp: @at)
      assert_not response.success?
      assert_nil response.data
    end
  end

  test "a USD pair is not silently substituted for an EUR quote" do
    response = @provider.fetch_security_price_at(symbol: "CRYPTO:BTCUSD", timestamp: @at)
    assert_not response.success?
    assert_not_requested :get, @url
  end

  private

    def stub_quote(rows)
      stub_request(:get, @url).with(query: {
        symbol: "BTCEUR", interval: "1m", startTime: (@minute.to_i * 1000).to_s,
        endTime: (@minute.to_i * 1000 + 59_999).to_s, limit: "1"
      }).to_return(status: 200, body: rows.to_json)
    end
end
