# Database-free CLI contract tests; never use a real broker session.
require "active_support/all"
require "minitest/autorun"
require "mocha/minitest"
require "tmpdir"
require "pathname"
require "ostruct"
require_relative "../../../app/models/provider"
require_relative "../../../app/models/provider/scalable_capital"

class Provider::ScalableCapitalTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("scalable-capital-test")
    @provider = Provider::ScalableCapital.new(OpenStruct.new)
    @provider.stubs(:session_directory).returns(Pathname.new(@directory))
    Provider::ScalableCapital.stubs(:available?).returns(true)
    @success = OpenStruct.new(success?: true)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_reads_every_page_and_pins_the_resolved_portfolio
    expect_command([ "broker", "overview" ], identity.merge("valuation" => { "total" => "10" }))
    expect_command([ "broker", "holdings", "--portfolio-id", "portfolio-1" ], identity.merge("count" => 0, "items" => []))
    expect_command([ "broker", "cash-breakdown", "--portfolio-id", "portfolio-1" ], identity.merge("cash_balance" => "10"))
    expect_command([ "broker", "transactions", "--portfolio-id", "portfolio-1", "--page-size", "100" ], { "items" => [ { "id" => "a", "summary_type" => "BrokerSecurityTransactionSummary" } ], "cursor" => "page-2", "total" => 2 })
    expect_command([ "broker", "transactions", "--portfolio-id", "portfolio-1", "--page-size", "100", "--cursor", "page-2" ], { "items" => [ { "id" => "b", "summary_type" => "BrokerSecurityTransactionSummary" } ], "cursor" => nil, "total" => 2 })
    %w[a b].each do |id|
      expect_command([ "broker", "transaction", "details", "--portfolio-id", "portfolio-1", "--transaction-id", id ], identity.merge("id" => id))
    end

    snapshot = @provider.snapshot
    assert_equal %w[a b], snapshot["transactions"].map { |row| row["id"] }
  end

  def test_cash_movements_do_not_trigger_a_detail_call
    expect_command([ "broker", "overview" ], identity)
    expect_command([ "broker", "holdings", "--portfolio-id", "portfolio-1" ], identity.merge("count" => 0, "items" => []))
    expect_command([ "broker", "cash-breakdown", "--portfolio-id", "portfolio-1" ], identity.merge("cash_balance" => "10"))
    expect_command([ "broker", "transactions", "--portfolio-id", "portfolio-1", "--page-size", "100" ], {
      "items" => [ { "id" => "cash-1", "summary_type" => "BrokerCashTransactionSummary" } ],
      "cursor" => nil, "total" => 1
    })
    @provider.expects(:capture).with("broker", "transaction", "details", anything, anything, anything, anything, "--json").never

    snapshot = @provider.snapshot
    assert_nil snapshot["transactions"].first["details"]
  end

  def test_a_truncated_history_is_not_a_successful_sync
    stub_empty_snapshot_reads
    expect_command([ "broker", "transactions", "--portfolio-id", "portfolio-1", "--page-size", "100" ], { "items" => [], "cursor" => nil, "total" => 100 })
    assert_raises(Provider::ScalableCapital::InvalidDataError) { @provider.snapshot }
  end

  def test_repeated_cursor_is_rejected
    stub_empty_snapshot_reads
    expect_command([ "broker", "transactions", "--portfolio-id", "portfolio-1", "--page-size", "100" ], { "items" => [ { "id" => "a" } ], "cursor" => "same" })
    expect_command([ "broker", "transactions", "--portfolio-id", "portfolio-1", "--page-size", "100", "--cursor", "same" ], { "items" => [ { "id" => "b" } ], "cursor" => "same" })
    assert_raises(Provider::ScalableCapital::InvalidDataError) { @provider.snapshot }
  end

  def test_upstream_errors_never_expose_messages_or_credentials
    body = { "ok" => false, "error" => { "code" => "no_session", "message" => "secret-access-token" } }.to_json
    @provider.expects(:capture).with("broker", "overview", "--json").returns([ body, OpenStruct.new(success?: false) ])
    error = assert_raises(Provider::ScalableCapital::AuthenticationError) { @provider.snapshot }
    refute_includes error.message, "secret-access-token"
  end

  def test_malformed_envelope_is_rejected
    @provider.expects(:capture).returns([ "[]", @success ])
    assert_raises(Provider::ScalableCapital::InvalidDataError) { @provider.snapshot }
  end

  # The regression behind "returned an incomplete holdings list": the CLI
  # wraps the projection, and reading the wrapper instead of the result made
  # every field look missing.
  def test_wrapped_results_are_read_from_the_result_object
    expect_command([ "broker", "overview" ], identity)
    expect_command([ "broker", "holdings", "--portfolio-id", "portfolio-1" ], { "count" => 1, "items" => [ { "isin" => "IE00BJ0KDQ92" } ] })
    expect_command([ "broker", "cash-breakdown", "--portfolio-id", "portfolio-1" ], { "cash_balance" => "2" })
    expect_command([ "broker", "transactions", "--portfolio-id", "portfolio-1", "--page-size", "100" ], { "items" => [], "cursor" => nil, "total" => 0 })

    snapshot = @provider.snapshot

    assert_equal 1, snapshot["holdings"].size
    assert_equal "IE00BJ0KDQ92", snapshot["holdings"].first["isin"]
    # The provider keeps the raw CLI values; the normalizer converts them.
    assert_equal "2", snapshot["cash"]["cash_balance"]
  end

  def test_a_flat_payload_is_still_accepted
    flat = { "ok" => true, "data" => identity.merge("count" => 0, "items" => [], "cash_balance" => "2", "portfolio_id" => "portfolio-1") }
    @provider.expects(:capture).with("broker", "overview", "--json").returns([ flat.to_json, @success ])
    @provider.expects(:capture).with("broker", "holdings", "--portfolio-id", "portfolio-1", "--json").returns([ flat.to_json, @success ])
    @provider.expects(:capture).with("broker", "cash-breakdown", "--portfolio-id", "portfolio-1", "--json").returns([ flat.to_json, @success ])
    @provider.expects(:capture).with("broker", "transactions", "--portfolio-id", "portfolio-1", "--page-size", "100", "--json").returns([ flat.to_json, @success ])

    snapshot = @provider.snapshot

    assert_equal [], snapshot["holdings"]
  end

  def test_login_uses_file_storage_and_the_local_read_only_guard
    environment = {
      "HOME" => @directory,
      "XDG_CONFIG_HOME" => File.join(@directory, ".config"),
      "SC_CONFIG_DIR" => File.join(@directory, ".config", "scalable-cli")
    }
    @provider.expects(:system).with(environment, Provider::ScalableCapital.executable, "login", "--local-read-only").returns(true)
    @provider.login!
    config_path = File.join(@directory, ".config", "scalable-cli", "config.toml")
    config = File.read(config_path)
    assert_includes config, 'session_backend = "file"'
    assert_equal 0o700, File.stat(@directory).mode & 0o777
    assert_equal 0o600, File.stat(config_path).mode & 0o777
  end

  def test_busy_session_does_not_race_token_refresh_or_login
    File.open(File.join(@directory, "wallet.lock"), File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
      @provider.expects(:capture).never
      assert_raises(Provider::ScalableCapital::Error) { @provider.snapshot }
    end
  end

  private

    def identity
      { "account_id" => "account-1", "portfolio_id" => "portfolio-1" }
    end

    # The CLI answers with the projection wrapped in `data.result`, next to the
    # resolved identifiers and the resolution metadata. Reproducing that exact
    # envelope is what caught the first integration: a flat payload made the
    # tests pass while the real command failed.
    def expect_command(args, result)
      envelope = {
        "ok" => true,
        "command" => args.join("."),
        "data" => identity.merge("resolution" => { "account" => "selected_context", "portfolio" => "explicit" })
                              .merge("result" => result.merge(identity))
      }
      @provider.expects(:capture).with(*args, "--json").returns([ envelope.to_json, @success ])
    end

    def stub_empty_snapshot_reads
      expect_command([ "broker", "overview" ], identity)
      expect_command([ "broker", "holdings", "--portfolio-id", "portfolio-1" ], identity.merge("count" => 0, "items" => []))
      expect_command([ "broker", "cash-breakdown", "--portfolio-id", "portfolio-1" ], identity.merge("cash_balance" => "10"))
    end
end
