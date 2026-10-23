module CryptoActivitiesHelper
  def crypto_ledger_row(entry)
    return unless entry.account.crypto? && !entry.valuation?
    @crypto_ledgers ||= {}
    ledger = @crypto_ledgers[entry.account_id] ||= Crypto::Ledger.new(entry.account, entries: [])
    @crypto_ledger_rows ||= {}
    @crypto_ledger_rows[entry.id] ||= ledger.row_for(entry)
  end

  def crypto_native(value, symbol, signed: false)
    return t("crypto_ledger.not_provided") if value.nil?
    prefix = signed && value.positive? ? "+" : ""
    "#{prefix}#{number_with_precision(value, precision: 18, strip_insignificant_zeros: true)} #{symbol}"
  end

  def crypto_euro(value, signed: false)
    return t("crypto_ledger.not_provided") if value.nil?
    precision = !value.zero? && value.abs < 0.01 ? 18 : 2
    "#{signed && value.positive? ? '+' : ''}#{format_money(Money.new(value, 'EUR'), precision: precision, strip_insignificant_zeros: precision > 2)}"
  end

  def crypto_time_label(row)
    row.occurred_at ? l(row.occurred_at, format: "%d/%m/%Y %H:%M:%S %Z") : "#{l(row.entry.date)} · #{t('crypto_ledger.time_unavailable')}"
  end

  def crypto_action_label(row)
    t("crypto_ledger.actions.#{row.action}", default: t("crypto_ledger.actions.other"))
  end

  def crypto_action_tone(row)
    { "buy" => :info, "sell" => :warning, "swap" => :info, "reward" => :success }.fetch(row.action, :neutral)
  end

  def crypto_overview_fields(row)
    [
      [ "description", row.description ],
      [ "occurred_at", crypto_time_label(row) ],
      [ "action", crypto_action_label(row) ],
      [ "quantity", crypto_native(row.quantity, row.symbol, signed: true) ],
      [ "value_eur", crypto_euro(row.euro_value, signed: true) ]
    ]
  end

  def crypto_detail_fields(row)
    fees = row.fees.map do |fee|
      "#{crypto_native(fee[:quantity], fee[:symbol] || t('crypto_ledger.unspecified_unit'))} (#{t("crypto_ledger.fee_kinds.#{fee[:kind]}")})"
    end
    [
      [ "unit_price_eur", "1 #{row.symbol} = #{crypto_euro(row.unit_price_eur)}" ],
      [ "fees", fees.presence&.join(" · ") || t("crypto_ledger.not_provided") ],
      [ "balance_after", crypto_native(row.balance_after, row.symbol) ],
      [ "price_source", t("crypto_ledger.sources.#{row.price_source}", default: t("crypto_ledger.not_provided")) ]
    ]
  end
end
