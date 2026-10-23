# Validates a complete snapshot before any canonical financial records change.
# A fiat purchase/sale becomes one Trade (including its cash effect), not a
# Trade plus its fiat counterpart. Both upstream legs remain in the metadata.
class Provider::Bitpanda::Normalizer
  REVIEW_REQUIRED_TYPES = %w[reclaim refund].freeze

  def initialize(snapshot)
    @snapshot = snapshot
    unless snapshot.is_a?(Hash) && %w[portfolio operations].all? { |key| records?(snapshot[key]) }
      raise Provider::Bitpanda::InvalidDataError, "Incomplete Bitpanda snapshot"
    end
    @assets = index(snapshot.fetch("assets"))
    @currencies = index(snapshot.fetch("currencies"))
    @eur_id = @currencies.values.find { |row| row["symbol"] == "EUR" }&.fetch("id")
    raise Provider::Bitpanda::InvalidDataError, "Missing Bitpanda EUR currency" unless @eur_id
  rescue KeyError, TypeError
    raise Provider::Bitpanda::InvalidDataError, "Incomplete Bitpanda snapshot"
  end

  def date
    Date.iso8601(@snapshot.fetch("date"))
  end

  def positions
    @positions ||= @snapshot.fetch("portfolio").map do |row|
      unless row["balance"].is_a?(Hash)
        raise Provider::Bitpanda::InvalidDataError, "Incomplete Bitpanda portfolio amounts"
      end
      asset_id = row["asset_id"].presence
      id = asset_id || row.fetch("currency_id")
      metadata = (asset_id ? @assets : @currencies).fetch(id)
      validate_unit!(row.fetch("balance"), id)
      quantity = decimal(row.fetch("balance").fetch("value"))
      amount = portfolio_amount(row, asset_id: asset_id, metadata: metadata, quantity: quantity)
      raise Provider::Bitpanda::InvalidDataError, "Bitpanda returned a negative position" if quantity.negative? || amount.negative?
      raise Provider::Bitpanda::InvalidDataError, "Bitpanda returned value for an empty position" if quantity.zero? && !amount.zero?

      { id: id, asset: asset_id.present?, symbol: metadata.fetch("symbol"),
        name: metadata.fetch("name"), type: metadata["type"], quantity: quantity, amount: amount }
    end.tap do |rows|
      if rows.map { |row| row[:id] }.uniq.size != rows.size
        raise Provider::Bitpanda::InvalidDataError, "Bitpanda returned duplicate portfolio positions"
      end
    end
  rescue KeyError, TypeError
    raise Provider::Bitpanda::InvalidDataError, "Incomplete Bitpanda portfolio position"
  end

  def activities
    @activities ||= begin
      seen = {}
      @snapshot.fetch("operations").flat_map do |operation|
        rows = operation.fetch("transactions")
        valid_rows = records?(rows) && rows.any? && rows.all? do |row|
          row["asset_amount"].is_a?(Hash) && (row["trade"].nil? || row["trade"].is_a?(Hash))
        end
        unless valid_rows
          raise Provider::Bitpanda::InvalidDataError, "Bitpanda operation has invalid transactions"
        end

        rows.map do |row|
          id = row.fetch("transaction_id")
          raise Provider::Bitpanda::InvalidDataError, "Bitpanda transaction has no identifier" unless id.is_a?(String) && id.present?
          signature = [ operation.fetch("operation_id"), row ]
          if seen.key?(id)
            raise Provider::Bitpanda::InvalidDataError, "Bitpanda returned conflicting transactions" unless seen[id] == signature
            next
          end
          seen[id] = signature
          activity(operation, rows, row)
        end.compact
      end
    end
  rescue KeyError, TypeError, ArgumentError
    raise Provider::Bitpanda::InvalidDataError, "Incomplete or invalid Bitpanda transaction"
  end

  private

    def records?(rows)
      rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) }
    end

    def index(rows)
      unless records?(rows)
        raise Provider::Bitpanda::InvalidDataError, "Invalid Bitpanda asset catalogue"
      end
      result = rows.to_h do |row|
        id = row.fetch("id")
        unless row.values_at("id", "symbol", "name").all? { |value| value.is_a?(String) && value.present? }
          raise Provider::Bitpanda::InvalidDataError, "Incomplete Bitpanda asset catalogue"
        end
        [ id, row ]
      end
      raise Provider::Bitpanda::InvalidDataError, "Duplicate Bitpanda catalogue identifiers" unless result.size == rows.size
      result
    end

    def decimal(value)
      number = BigDecimal(value.to_s, exception: false)
      raise Provider::Bitpanda::InvalidDataError, "Invalid Bitpanda decimal amount" unless number&.finite?
      number
    end

    def validate_unit!(amount, expected_id)
      actual_id = amount["asset_id"].presence || amount["currency_id"].presence
      if actual_id && actual_id != expected_id
        raise Provider::Bitpanda::InvalidDataError, "Bitpanda amount references a different asset"
      end
    end

    def portfolio_amount(row, asset_id:, metadata:, quantity:)
      value = row["currency_balance"]
      # The Public API omits currency_balance on fiat wallets. Their balance
      # is already denominated in the wallet currency, not an absent valuation.
      if value.nil? && asset_id.nil?
        return quantity if metadata.fetch("symbol") == "EUR" || quantity.zero?

        rate = ExchangeRate.find_or_fetch_rate(from: metadata.fetch("symbol"), to: "EUR", date: date)
        unless rate && rate.date == date && decimal(rate.rate).positive?
          raise Provider::Bitpanda::InvalidDataError, "Bitpanda fiat balance requires an exact-date EUR exchange rate"
        end
        return quantity * decimal(rate.rate)
      end

      unless value.is_a?(Hash)
        raise Provider::Bitpanda::InvalidDataError, "Incomplete Bitpanda portfolio amounts"
      end
      unless value["currency_id"] == @eur_id
        raise Provider::Bitpanda::InvalidDataError, "Bitpanda portfolio valuation is not in EUR"
      end
      decimal(value.fetch("value"))
    end

    def activity(operation, rows, row)
      flow = row.fetch("flow")
      unless %w[INCOMING OUTGOING].include?(flow)
        raise Provider::Bitpanda::InvalidDataError, "Unknown Bitpanda transaction direction"
      end
      asset_id = row["asset_id"].presence
      metadata = (asset_id ? @assets : @currencies).fetch(asset_id || row.fetch("currency_id"))
      validate_unit!(row.fetch("asset_amount"), metadata.fetch("id"))
      quantity = decimal(row.fetch("asset_amount").fetch("value")).abs
      direction = flow == "INCOMING" ? 1 : -1
      operation_type = operation.fetch("operation_type")
      # Ordinary buys, deposits and rewards can omit the per-leg subtype.
      # The parent operation remains authoritative; unknown types still fail.
      type = row["transaction_type"].presence || operation_type
      review_required = REVIEW_REQUIRED_TYPES.include?(operation_type.to_s.downcase)
      trade_id = row.dig("trade", "trade_id")
      trading_rows = trade_id.present? ? rows.select { |leg| leg.dig("trade", "trade_id") == trade_id } : rows
      asset_rows = trading_rows.select { |leg| leg["asset_id"].present? }
      cash_rows = trading_rows.select { |leg| leg["asset_id"].blank? && leg["currency_id"].present? }
      paired_trade = !review_required && asset_rows.one? && cash_rows.one? && asset_rows.first["trade"].present? &&
        cash_rows.first.dig("trade", "trade_id").present? &&
        asset_rows.first.dig("trade", "trade_id") == cash_rows.first.dig("trade", "trade_id")
      if paired_trade && decimal(asset_rows.first.fetch("asset_amount").fetch("value")).zero?
        raise Provider::Bitpanda::InvalidDataError, "Bitpanda trade has no asset quantity"
      end
      # The fiat leg is represented by the trade's cash amount, not a second entry.
      return nil if !asset_id && paired_trade

      label = if review_required
        # These are non-trading balance corrections, not evidence of an
        # acquisition/disposal price. Reuse cash-neutral quantity movements,
        # explicitly marking their financial classification for review.
        "Transfer"
      elsif row["trade"].present?
        if operation_type.to_s.downcase == "swap"
          "Exchange"
        else
          asset_id && cash_rows.any? ? (direction.positive? ? "Buy" : "Sell") : "Exchange"
        end
      elsif "#{operation_type} #{type}".match?(/reward|interest|dividend/i)
        "Dividend"
      elsif "#{operation_type} #{type}".match?(/fee/i)
        "Fee"
      else
        # Unknown operations must not silently become income or taxable sales.
        unless "#{operation_type} #{type}".match?(/deposit|withdraw|transfer|stak(?:e|ing)/i)
          raise Provider::Bitpanda::InvalidDataError, "Unsupported Bitpanda operation type: #{operation_type} / #{type}"
        end
        "Transfer"
      end

      result = {
        external_id: "bitpanda_#{row.fetch('transaction_id')}", asset: asset_id.present?,
        asset_id: asset_id, symbol: metadata.fetch("symbol"), security_name: metadata.fetch("name"),
        asset_type: metadata["type"], quantity: quantity * direction,
        date: Time.iso8601(row.fetch("credited_at")).to_date, label: label,
        currency: asset_id ? "EUR" : metadata.fetch("symbol"),
        amount: asset_id ? 0.to_d : -quantity * direction,
        price: nil,
        metadata: { "operation_id" => operation.fetch("operation_id"), "operation_type" => operation_type,
          "description" => row["description"].presence || operation["description"].presence,
          "transaction" => row, "operation_transactions" => rows }
      }
      result[:metadata]["review_required"] = true if review_required

      # A one-asset/one-fiat trade supplies an exact execution value without
      # interpreting the API's undocumented rate/to_eur_rate relationship.
      if asset_id && paired_trade && quantity.positive?
        cash = cash_rows.first
        if cash.fetch("flow") == flow
          raise Provider::Bitpanda::InvalidDataError, "Bitpanda trade legs have the same direction"
        end
        result[:currency] = @currencies.fetch(cash.fetch("currency_id")).fetch("symbol")
        cost = decimal(cash.fetch("asset_amount").fetch("value")).abs
        raise Provider::Bitpanda::InvalidDataError, "Bitpanda trade has no execution value" unless cost.positive?
        rate = row.dig("trade", "rate_with_fee")
        result[:price] = rate.present? ? decimal(rate) : cost / quantity
        raise Provider::Bitpanda::InvalidDataError, "Bitpanda trade has an invalid execution rate" unless result[:price].positive?
        result[:amount] = cost * direction
        result[:fee] = decimal(row.dig("trade", "fee", "value")) if row.dig("trade", "fee", "value").present?
        result[:metadata]["cash_transaction_id"] = cash.fetch("transaction_id")
      end
      result
    end
end
