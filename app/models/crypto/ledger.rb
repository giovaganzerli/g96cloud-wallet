# A display ledger of native movements. Entry.amount remains the accounting
# cash effect and is deliberately NOT used as a crypto movement's valuation.
class Crypto::Ledger
  Row = Struct.new(:entry, :description, :occurred_at, :action, :symbol, :quantity,
    :euro_value, :unit_price_eur, :fees, :balance_after, :price_source, :cash_delta_eur, keyword_init: true)
  ACTIONS = { "buy" => "buy", "sell" => "sell", "swap" => "swap", "deposit" => "deposit",
    "withdrawal" => "withdrawal", "withdraw" => "withdrawal", "reclaim" => "correction", "refund" => "correction",
    "passive_earn_reward" => "reward", "onetime_reward" => "reward", "staking_reward" => "reward" }.freeze

  def initialize(account, entries:)
    @account = account
    @entries = entries.reject(&:excluded?)
    @fx = {}
  end

  def rows
    @rows ||= begin
      if @account.manual?
        history = @account.entries.where(excluded: false).includes(:entryable).to_a
        preload_securities(history)
        all = history.filter_map { |entry| build(entry) }.sort_by { |row| [ row.occurred_at || row.entry.date.in_time_zone, row.entry.created_at, row.entry.id ] }
        balances = Hash.new(opening_unknown? ? nil : 0.to_d)
        all.each do |row|
          if row.balance_after
            balances[row.symbol] = row.balance_after
          elsif balances[row.symbol]
            movement = row.symbol == "EUR" ? (row.cash_delta_eur || row.quantity) : row.quantity
            balances[row.symbol] += movement
            row.balance_after = balances[row.symbol]
          end
          if row.symbol != "EUR" && row.cash_delta_eur && balances["EUR"]
            balances["EUR"] += row.cash_delta_eur
          end
        end
        @historical_rows = all.index_by { |row| row.entry.id }
        ids = @entries.map(&:id).to_set
        all.select { |row| ids.include?(row.entry.id) }.reverse
      else
        preload_securities(@entries)
        @entries.filter_map { |entry| build(entry) }.sort_by { |row| [ row.occurred_at || row.entry.date.in_time_zone, row.entry.created_at, row.entry.id ] }.reverse
      end
    end
  end

  def opening_unknown?
    return @opening_unknown if defined?(@opening_unknown)
    anchor = @account.valuations.opening_anchor.includes(:entry).first
    @opening_unknown = anchor.present? && !anchor.entry.amount.zero?
  end

  def row_for(entry)
    rows
    @historical_rows&.[](entry.id) || rows.find { |row| row.entry.id == entry.id } || build(entry)
  end

  private

    def preload_securities(entries)
      trades = entries.select(&:trade?).map(&:trade)
      ActiveRecord::Associations::Preloader.new(records: trades, associations: :security).call if trades.any?
    end

    def build(entry)
      return if entry.valuation?
      metadata = entry.entryable.extra.to_h
      if entry.source == "bitpanda" && metadata["bitpanda"].is_a?(Hash)
        bitpanda_row(entry, metadata["bitpanda"])
      elsif metadata["crypto"].is_a?(Hash)
        manual_row(entry, metadata["crypto"])
      else
        legacy_row(entry)
      end
    end

    def decimal(value)
      number = BigDecimal(value.to_s, exception: false)
      number if number&.finite?
    end

    def timestamp(value)
      Time.iso8601(value).in_time_zone if value.present?
    rescue ArgumentError
      nil
    end

    def catalogue
      @catalogue ||= @account.account_providers.includes(:provider).each_with_object({}) do |link, result|
        next unless link.provider_type == "BitpandaAccount"
        snapshot = link.provider.raw_payload.to_h
        (Array(snapshot["assets"]) + Array(snapshot["currencies"])).each { |asset| result[asset["id"]] = asset }
      end
    end

    def fx(currency, date)
      return 1.to_d if currency == "EUR"
      @fx[[ currency, date ]] ||= begin
        value = ExchangeRate.find_by(from_currency: currency, to_currency: "EUR", date: date)&.rate
        value if value&.positive?
      end
    end

    def bitpanda_row(entry, metadata)
      raw = metadata.fetch("transaction")
      asset = catalogue[raw["asset_id"].presence || raw["currency_id"]]
      return legacy_row(entry) unless asset
      symbol = asset.fetch("symbol")
      qty = decimal(raw.dig("asset_amount", "value"))&.abs
      return unless qty
      qty = -qty if raw["flow"] == "OUTGOING"
      action = ACTIONS.fetch(metadata["operation_type"].to_s.downcase, "other")
      action = qty.positive? ? "buy" : "sell" if action == "other" && entry.trade? && raw["trade"].present?
      trade_id = raw.dig("trade", "trade_id")
      cash = if trade_id.present?
        Array(metadata["operation_transactions"]).find { |leg| leg["asset_id"].blank? && leg.dig("trade", "trade_id") == trade_id }
      end
      cash_currency = catalogue.dig(cash&.dig("currency_id"), "symbol")
      price = nil
      value = nil
      source = "not_provided"
      if raw["asset_id"].blank?
        rate = fx(symbol, entry.date)
        price, value, source = rate, rate && qty * rate, "bitpanda"
      elsif cash && (rate = fx(cash_currency, entry.date))
        provided = decimal(raw.dig("trade", "rate_with_fee"))
        price = (provided || (qty.zero? ? nil : decimal(cash.dig("asset_amount", "value"))&.abs&./(qty.abs)))
        price *= rate if price
        value = decimal(cash.dig("asset_amount", "value"))&.abs&.*(rate)
        value = -value if value && qty.negative?
        source = cash_currency == "EUR" ? "bitpanda" : "bitpanda_fx"
      elsif entry.trade? && entry.trade.price.positive? && (rate = fx(entry.trade.currency, entry.date))
        price = entry.trade.price * rate
        value = qty * price
        source = "market_daily"
      end
      fees = []
      movement_fee = decimal(raw.dig("fee_amount", "value"))
      fee_unit = raw.dig("fee_amount", "currency_id").presence || raw.dig("fee_amount", "asset_id")
      fees << { quantity: movement_fee, symbol: catalogue.dig(fee_unit, "symbol"), kind: "movement" } if movement_fee
      trading_fee = decimal(raw.dig("trade", "fee", "value"))
      if trading_fee&.positive?
        # Trade.fee is in the trade quote's units. The API's asset_id also
        # identifies the traded instrument, not a fee of e.g. 1 whole BTC.
        fees.reject! { |fee| fee[:quantity].zero? }
        fees << { quantity: trading_fee, symbol: cash_currency, kind: "trading" }
      end
      Row.new(entry: entry, description: metadata["description"].presence || raw["description"].presence || "#{I18n.t("crypto_ledger.actions.#{action}")} #{symbol}",
        occurred_at: timestamp(raw["credited_at"]) || entry.occurred_at, action: action,
        symbol: symbol, quantity: qty, euro_value: value, unit_price_eur: price,
        fees: fees, balance_after: decimal(raw.dig("asset_balance_after", "value")), price_source: source)
    end

    def manual_row(entry, data)
      Row.new(entry: entry, description: entry.name, occurred_at: entry.occurred_at || timestamp(data["occurred_at"]),
        action: data.fetch("kind"), symbol: data.fetch("symbol"), quantity: decimal(data["quantity"]),
        euro_value: decimal(data["value_eur"]), unit_price_eur: decimal(data["unit_price_eur"]),
        fees: [ { quantity: decimal(data["fee_eur"]), symbol: "EUR", kind: "trading" } ],
        balance_after: decimal(data["balance_after"]), price_source: data["price_source"], cash_delta_eur: decimal(data["cash_delta_eur"]))
    end

    def legacy_row(entry)
      trade = entry.trade? ? entry.trade : nil
      rate = fx(entry.currency, entry.date)
      if trade && !trade.qty.zero?
        symbol = trade.security.crypto_base_asset.presence || trade.security.ticker.delete_prefix("CRYPTO:")
        price = trade.price.positive? && rate ? trade.price * rate : nil
        action = { "Buy" => "buy", "Sell" => "sell", "Exchange" => "swap", "Transfer" => "deposit" }.fetch(trade.investment_activity_label, "other")
        Row.new(entry: entry, description: entry.name, occurred_at: entry.occurred_at,
          action: action, symbol: symbol, quantity: trade.qty, euro_value: price && trade.qty * price,
          unit_price_eur: price, fees: [ { quantity: trade.fee, symbol: entry.currency, kind: "trading" } ],
          price_source: "manual", cash_delta_eur: rate && -entry.amount * rate)
      else
        qty = -entry.amount
        Row.new(entry: entry, description: entry.name, occurred_at: entry.occurred_at,
          action: qty.positive? ? "deposit" : "withdrawal", symbol: entry.currency, quantity: qty,
          euro_value: rate && qty * rate, unit_price_eur: rate, fees: [],
          price_source: "manual", cash_delta_eur: rate && qty * rate)
      end
    end
end
