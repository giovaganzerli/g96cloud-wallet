require "test_helper"

class Provider::BitpandaTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Bitpanda.new(api_key: "never-log-this-key")
    @base = Provider::Bitpanda::BASE_URL
  end

  test "uses only authenticated GETs and follows every assets and operations page" do
    currencies = [ { "id" => "eur", "symbol" => "EUR" } ]
    expect_get("currencies", { "data" => currencies })
    expect_get("assets?page_size=100", page([ { "id" => "btc" } ], "assets-2"))
    expect_get("assets?page_size=100&cursor=assets-2", page([ { "id" => "eth" } ]))
    expect_get("portfolio?equivalent_currency_id=eur", { "data" => [] })
    expect_get("operations?page_size=100", page([ { "operation_id" => "first" } ], "operations-2"))
    expect_get("operations?page_size=100&cursor=operations-2", page([ { "operation_id" => "second" } ]))

    result = @provider.snapshot
    assert_equal %w[btc eth], result["assets"].pluck("id")
    assert_equal %w[first second], result["operations"].pluck("operation_id")
  end

  test "rejects repeated and missing cursors rather than returning a partial history" do
    stub_initial_reads
    expect_get("operations?page_size=100", page([], "same"))
    expect_get("operations?page_size=100&cursor=same", page([], "same"))
    assert_raises(Provider::Bitpanda::InvalidDataError) { @provider.snapshot }
  end

  test "rejects incomplete pagination envelopes" do
    stub_initial_reads
    expect_get("operations?page_size=100", { "data" => [] })
    assert_raises(Provider::Bitpanda::InvalidDataError) { @provider.snapshot }
  end

  test "deduplicates identical overlapping pages" do
    stub_initial_reads
    row = { "operation_id" => "first" }
    expect_get("operations?page_size=100", page([ row ], "next"))
    expect_get("operations?page_size=100&cursor=next", page([ row ]))
    assert_equal [ row ], @provider.snapshot["operations"]
  end

  test "rejects conflicting duplicates" do
    stub_initial_reads
    expect_get("operations?page_size=100", page([ { "operation_id" => "first", "value" => "1" } ], "next"))
    expect_get("operations?page_size=100&cursor=next", page([ { "operation_id" => "first", "value" => "2" } ]))
    assert_raises(Provider::Bitpanda::InvalidDataError) { @provider.snapshot }
  end

  test "authentication and rate limit errors never expose upstream bodies" do
    [ [ 401, Provider::Bitpanda::AuthenticationError ], [ 403, Provider::Bitpanda::AuthenticationError ],
      [ 429, Provider::Bitpanda::Error ], [ 500, Provider::Bitpanda::Error ] ].each do |status, klass|
      stub_request(:get, "#{@base}currencies").to_return(status: status, body: "never-log-this-key")
      error = assert_raises(klass) { @provider.snapshot }
      refute_includes error.message, "never-log-this-key"
    end
  end

  test "malformed JSON and non-object envelopes are rejected" do
    [ "not-json", "[]", '{"data":null}' ].each do |body|
      stub_request(:get, "#{@base}currencies").to_return(status: 200, body: body)
      assert_raises(Provider::Bitpanda::InvalidDataError) { @provider.snapshot }
    end
  end

  private

    def page(rows, cursor = nil)
      { "data" => rows, "has_next_page" => cursor.present?, "next_cursor" => cursor }
    end

    def stub_initial_reads
      expect_get("currencies", { "data" => [ { "id" => "eur", "symbol" => "EUR" } ] })
      expect_get("assets?page_size=100", page([]))
      expect_get("portfolio?equivalent_currency_id=eur", { "data" => [] })
    end

    def expect_get(path, payload)
      stub_request(:get, "#{@base}#{path}")
        .with(headers: { "x-api-key" => "never-log-this-key", "Accept" => "application/json" })
        .to_return(status: 200, body: JSON.generate(payload))
    end
end
