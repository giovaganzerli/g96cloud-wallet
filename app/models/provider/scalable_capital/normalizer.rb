# Normalizes the official Scalable CLI v1.1 JSON projections. Unknown booked
# events fail closed instead of silently producing an incomplete financial ledger.
class Provider::ScalableCapital::Normalizer
  Error = Provider::ScalableCapital::InvalidDataError
  CURRENCY = "EUR".freeze
  CASH_IN = %w[DEPOSIT DISTRIBUTION DIVIDEND INTEREST TAX_RETURN CASH_TRANSFER_IN POCKET_MONEY REINVESTMENT_DISTRIBUTION REINVESTMENT_POCKET_MONEY].freeze
  CASH_OUT = %w[WITHDRAWAL FEE TAX CASH_TRANSFER_OUT].freeze
  UNBOOKED = %w[CREATED REQUESTED PENDING CANCEL_REQUESTED PARTIAL_FILLED].freeze
  UNEXECUTED = %w[CANCELLED EXPIRED REJECTED].freeze
  BOOKED = %w[FILLED SETTLED CONFIRMED].freeze

  def initialize(snapshot)
    @snapshot = snapshot
  end

  def holdings
    rows = @snapshot.fetch("holdings")
    raise Error, "Invalid Scalable Capital holdings" unless rows.is_a?(Array)

    rows.map do |row|
      quantity = decimal(row.fetch("quantity"))
      raise Error, "Invalid Scalable Capital position quantity" if quantity.negative?
      amount = decimal(row.fetch("valuation"))
      currency!(row.fetch("valuation_currency"))
      raise Error, "Invalid Scalable Capital position value" if amount.negative? || (quantity.zero? && !amount.zero?)

      {
        isin: isin!(row.fetch("isin")), name: row["name"], quantity: quantity,
        amount: amount, price: quantity.zero? ? 0.to_d : amount / quantity,
        currency: CURRENCY, date: date!,
        cost_basis: row["fifo_price"].present? && row["quote_currency"] == CURRENCY ? decimal(row["fifo_price"]) : nil
      }
    end
  rescue KeyError, TypeError
    raise Error, "Incomplete Scalable Capital holdings"
  end

  def cash_balance
    decimal(@snapshot.fetch("cash").fetch("cash_balance"))
  rescue KeyError, TypeError
    raise Error, "Missing Scalable Capital cash balance"
  end

  def activities
    rows = @snapshot.fetch("transactions")
    raise Error, "Invalid Scalable Capital history" unless rows.is_a?(Array)
    rows.filter_map { |row| activity(row) }
  rescue KeyError, TypeError
    raise Error, "Incomplete Scalable Capital transaction history"
  end

  private

    def activity(row)
      details = row["details"]
      if details
        raise Error, "Mismatched Scalable Capital transaction" unless row.fetch("id") == details.fetch("id")
      end
      status = row.fetch("status")
      return if UNBOOKED.include?(status) || details&.dig("is_pending") == true
      # A cancelled, partially executed order must not disappear without warning.
      if UNEXECUTED.include?(status)
        filled = details&.dig("security_trade", "number_of_shares", "filled")
        raise Error, "Partially executed Scalable Capital order requires reconciliation" if filled.present? && decimal(filled).positive?
        return
      end
      raise Error, "Unknown Scalable Capital transaction status" unless BOOKED.include?(status)

      currency!(row.fetch("currency"))
      common = {
        external_id: "scalable_capital_#{row.fetch('id')}",
        currency: CURRENCY,
        date: timestamp_date(row.fetch("last_event_datetime")),
        name: row["description"].presence || details&.dig("security", "name").presence || "Scalable Capital"
      }
      reversal = row["is_cancellation"] == true || details&.dig("is_cancellation") == true ? -1 : 1
      case row.fetch("summary_type")
      when "BrokerCashTransactionSummary"
        cash(row, common, reversal)
      when "BrokerSecurityTransactionSummary"
        trade(row, details, common, reversal)
      when "BrokerNonTradeSecurityTransactionSummary"
        security_transfer(row, details, common, reversal)
      else
        # ELTIF and any future summary type: unsupported, so the sync fails
        # instead of quietly dropping a booked movement.
        raise Error, "Unsupported Scalable Capital transaction type"
      end
    end

    def trade(row, details, common, reversal)
      raise Error, "Missing Scalable Capital trade details" if details.nil?

      data = details.fetch("security_trade")
      side = data.fetch("side")
      raise Error, "Unknown Scalable Capital trade direction" unless %w[BUY SELL].include?(side)
      direction = (side == "BUY" ? 1 : -1) * reversal
      quantity = decimal(data.fetch("number_of_shares").fetch("filled"))
      price = decimal(data.fetch("average_price"))
      raise Error, "Invalid Scalable Capital trade" unless quantity.positive? && price >= 0

      common.merge(
        kind: :trade, isin: isin!(details.fetch("security").fetch("isin")),
        security_name: details.dig("security", "name"),
        quantity: quantity * direction, price: price,
        # The broker's booked total already accounts for charges, so it is used
        # as the cash amount instead of quantity x price.
        amount: decimal(data.fetch("total_amount")).abs * direction,
        # Left unset when the broker reports no fee, so an unknown fee is not
        # recorded as a confirmed zero.
        fee: data["fee"].present? ? decimal(data["fee"]) : nil,
        activity_label: direction.positive? ? "Buy" : "Sell"
      )
    end

    def cash(row, common, reversal)
      type = row.fetch("cash_transaction_type")
      direction = if CASH_IN.include?(type)
        -1
      elsif CASH_OUT.include?(type)
        1
      else
        raise Error, "Unsupported Scalable Capital cash transaction type"
      end
      label = case type
      when "DISTRIBUTION", "DIVIDEND", "REINVESTMENT_DISTRIBUTION" then "Dividend"
      when "INTEREST" then "Interest"
      when "FEE" then "Fee"
      when "DEPOSIT", "CASH_TRANSFER_IN" then "Contribution"
      when "WITHDRAWAL", "CASH_TRANSFER_OUT" then "Withdrawal"
      else "Other"
      end
      common.merge(
        kind: :transaction, amount: decimal(row.fetch("amount")).abs * direction * reversal,
        investment_activity_label: label, extra: { "scalable_capital" => { "cash_transaction_type" => type } },
        replace_extra_namespaces: [ "scalable_capital" ]
      )
    end

    def security_transfer(row, details, common, reversal)
      raise Error, "Missing Scalable Capital corporate action details" if details.nil?

      data = details.fetch("non_trade_security")
      type = data.fetch("non_trade_security_transaction_type")
      raise Error, "Unsupported Scalable Capital corporate action" unless %w[TRANSFER_IN TRANSFER_OUT].include?(type)
      quantity = decimal(data.fetch("quantity"))
      raise Error, "Invalid Scalable Capital security transfer" unless quantity.positive?

      common.merge(
        kind: :trade, isin: isin!(data.fetch("isin")), security_name: details.dig("security", "name"),
        quantity: quantity * (type == "TRANSFER_IN" ? 1 : -1) * reversal,
        price: decimal(data.fetch("average_price")), amount: 0.to_d, activity_label: "Transfer"
      )
    end

    def decimal(value)
      result = BigDecimal(value.to_s)
      raise Error, "Non-finite Scalable Capital amount" unless result.finite?
      result
    rescue ArgumentError
      raise Error, "Invalid Scalable Capital amount"
    end

    def currency!(value)
      raise Error, "Unsupported Scalable Capital currency" unless value == CURRENCY
    end

    def isin!(value)
      raise Error, "Invalid Scalable Capital ISIN" unless value.is_a?(String) && value.match?(/\A[A-Z]{2}[A-Z0-9]{9}[0-9]\z/)
      value
    end

    def date!
      Date.iso8601(@snapshot.fetch("date"))
    rescue ArgumentError
      raise Error, "Invalid Scalable Capital snapshot date"
    end

    def timestamp_date(value)
      Time.iso8601(value.to_s).in_time_zone.to_date
    rescue ArgumentError
      raise Error, "Invalid Scalable Capital transaction date"
    end
end
