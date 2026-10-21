# Pure contract tests intentionally do not boot Rails or touch a database.
require "active_support/all"
require "minitest/autorun"
require_relative "../../../../app/models/provider"
require_relative "../../../../app/models/provider/scalable_capital"
require_relative "../../../../app/models/provider/scalable_capital/normalizer"

class Provider::ScalableCapital::NormalizerTest < Minitest::Test
  def setup
    @snapshot = {
      "date" => "2026-10-21", "holdings" => [], "transactions" => [],
      "cash" => { "cash_balance" => "123.45" }
    }
    @normalizer = Provider::ScalableCapital::Normalizer.new(@snapshot)
  end

  def test_cash_inflows_and_outflows_use_wallet_signs
    %w[DEPOSIT DISTRIBUTION INTEREST TAX_RETURN CASH_TRANSFER_IN].each do |type|
      @snapshot["transactions"] = [ cash(type, "10.25") ]
      assert_equal BigDecimal("-10.25"), @normalizer.activities.first[:amount], type
    end
    %w[WITHDRAWAL FEE TAX CASH_TRANSFER_OUT].each do |type|
      @snapshot["transactions"] = [ cash(type, "10.25") ]
      assert_equal BigDecimal("10.25"), @normalizer.activities.first[:amount], type
    end
  end

  def test_cash_movements_do_not_require_a_detail_call
    @snapshot["transactions"] = [ cash("DEPOSIT", "100") ]
    activity = @normalizer.activities.first
    assert_equal "Contribution", activity[:investment_activity_label]
    assert_equal Date.new(2026, 10, 20), activity[:date]
    assert_equal "scalable_capital_cash-1", activity[:external_id]
  end

  def test_buy_and_sell_preserve_fractional_quantity_and_booked_amount
    %w[BUY SELL].each do |side|
      @snapshot["transactions"] = [ trade(side) ]
      activity = @normalizer.activities.first
      direction = side == "BUY" ? 1 : -1
      assert_equal BigDecimal("0.123456") * direction, activity[:quantity]
      assert_equal BigDecimal("21.19") * direction, activity[:amount]
      assert_equal BigDecimal("170.5"), activity[:price]
      assert_equal "scalable_capital_trade-1", activity[:external_id]
    end
  end

  def test_reversals_reverse_both_cash_and_quantity
    row = trade("BUY")
    row["is_cancellation"] = true
    @snapshot["transactions"] = [ row ]
    assert_equal BigDecimal("-0.123456"), @normalizer.activities.first[:quantity]
    assert_equal BigDecimal("-21.19"), @normalizer.activities.first[:amount]

    row = cash("DEPOSIT", "100")
    row["is_cancellation"] = true
    @snapshot["transactions"] = [ row ]
    assert_equal BigDecimal("100"), @normalizer.activities.first[:amount]
  end

  def test_pending_and_unexecuted_orders_do_not_change_the_ledger
    row = trade("BUY")
    row["status"] = "PENDING"
    @snapshot["transactions"] = [ row ]
    assert_empty @normalizer.activities
    row["status"] = "CANCELLED"
    row["details"]["security_trade"]["number_of_shares"]["filled"] = "0"
    assert_empty @normalizer.activities
  end

  def test_cancelled_partially_executed_order_is_not_silently_omitted
    row = trade("BUY")
    row["status"] = "CANCELLED"
    @snapshot["transactions"] = [ row ]
    assert_raises(Provider::ScalableCapital::InvalidDataError) { @normalizer.activities }
  end

  def test_unknown_cash_types_and_unsupported_summary_types_fail_closed
    @snapshot["transactions"] = [ cash("FUTURE_CASH_TYPE", "100") ]
    assert_raises(Provider::ScalableCapital::InvalidDataError) { @normalizer.activities }

    row = trade("BUY")
    row["summary_type"] = "BrokerEltifTransactionSummary"
    @snapshot["transactions"] = [ row ]
    assert_raises(Provider::ScalableCapital::InvalidDataError) { @normalizer.activities }
  end

  def test_cash_balance_keeps_negative_cash
    @snapshot["cash"]["cash_balance"] = "-10.01"
    assert_equal BigDecimal("-10.01"), @normalizer.cash_balance
  end

  def test_missing_or_nonfinite_amounts_never_become_zero
    [ nil, "garbage", "NaN", "Infinity" ].each do |value|
      @snapshot["cash"]["cash_balance"] = value
      assert_raises(Provider::ScalableCapital::InvalidDataError) { @normalizer.cash_balance }
    end
  end

  def test_position_value_uses_valuation_currency_not_quote_currency
    @snapshot["holdings"] = [ {
      "isin" => "IE00B4L5Y983", "name" => "World ETF", "quantity" => "0.5",
      "valuation" => "50.25", "valuation_currency" => "EUR",
      "quote_mid_price" => "110", "quote_currency" => "USD", "fifo_price" => "90"
    } ]
    position = @normalizer.holdings.first
    assert_equal BigDecimal("100.5"), position[:price]
    assert_equal BigDecimal("50.25"), position[:amount]
    assert_equal "EUR", position[:currency]
    assert_nil position[:cost_basis]
    assert_equal Date.new(2026, 10, 21), position[:date]
  end

  def test_derived_price_is_rounded_to_the_stored_precision
    @snapshot["holdings"] = [ {
      "isin" => "IE00B4L5Y983", "name" => "World ETF", "quantity" => "3",
      "valuation" => "10", "valuation_currency" => "EUR", "quote_currency" => "EUR"
    } ]
    position = @normalizer.holdings.first

    assert_equal BigDecimal("3.3333"), position[:price]
  end

  def test_foreign_cash_and_missing_trade_identifiers_fail_closed
    row = cash("DEPOSIT", "100")
    row["currency"] = "USD"
    @snapshot["transactions"] = [ row ]
    assert_raises(Provider::ScalableCapital::InvalidDataError) { @normalizer.activities }
    row = trade("BUY")
    row["details"]["security"]["isin"] = nil
    @snapshot["transactions"] = [ row ]
    assert_raises(Provider::ScalableCapital::InvalidDataError) { @normalizer.activities }
  end

  def test_same_day_identical_cash_movements_keep_distinct_identifiers
    first = cash("DEPOSIT", "100")
    second = first.deep_dup
    second["id"] = "cash-2"
    @snapshot["transactions"] = [ first, second ]
    assert_equal 2, @normalizer.activities.map { |row| row[:external_id] }.uniq.size
  end

  def test_security_transfers_do_not_create_cash_flow
    row = trade("BUY")
    row["summary_type"] = "BrokerNonTradeSecurityTransactionSummary"
    row["details"] = {
      "id" => "trade-1", "detail_type" => "non_trade_security", "currency" => "EUR",
      "is_pending" => false, "security" => { "isin" => "IE00B4L5Y983", "name" => "World ETF" },
      "non_trade_security" => {
        "isin" => "IE00B4L5Y983", "non_trade_security_transaction_type" => "TRANSFER_IN",
        "quantity" => "1.25", "average_price" => "90"
      }
    }
    @snapshot["transactions"] = [ row ]
    activity = @normalizer.activities.first
    assert_equal "Transfer", activity[:activity_label]
    assert_equal 0, activity[:amount]
    assert_equal BigDecimal("1.25"), activity[:quantity]
  end

  def test_a_trade_without_details_cannot_be_imported
    row = trade("BUY")
    row.delete("details")
    @snapshot["transactions"] = [ row ]
    assert_raises(Provider::ScalableCapital::InvalidDataError) { @normalizer.activities }
  end

  private

    def cash(type, amount)
      {
        "id" => "cash-1", "summary_type" => "BrokerCashTransactionSummary", "status" => "SETTLED",
        "description" => type, "currency" => "EUR", "is_cancellation" => false,
        "last_event_datetime" => "2026-10-20T12:00:00Z",
        "cash_transaction_type" => type, "amount" => amount
      }
    end

    def trade(side)
      {
        "id" => "trade-1", "summary_type" => "BrokerSecurityTransactionSummary", "status" => "FILLED",
        "description" => "World ETF", "currency" => "EUR", "is_cancellation" => false,
        "last_event_datetime" => "2026-10-20T12:00:00Z",
        "details" => {
          "id" => "trade-1", "detail_type" => "security_trade", "currency" => "EUR",
          "last_event_datetime" => "2026-10-20T12:00:00Z", "is_pending" => false,
          "security" => { "isin" => "IE00B4L5Y983", "name" => "World ETF" },
          "security_trade" => {
            "side" => side, "number_of_shares" => { "filled" => "0.123456" },
            "average_price" => "170.5", "total_amount" => "21.19", "fee" => "0.21"
          }
        }
      }
    end
end
