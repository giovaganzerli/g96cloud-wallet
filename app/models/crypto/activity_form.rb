class Crypto::ActivityForm
  include ActiveModel::Model

  ACTIONS = %w[buy sell deposit withdrawal swap].freeze
  attr_accessor :account, :description, :occurred_at, :time_zone, :kind, :symbol,
    :quantity, :unit_price_eur, :value_eur, :fee_eur, :counter_symbol, :counter_quantity, :balance_after, :funded_from_wallet, :suggested_price
  attr_reader :entry

  validates :kind, inclusion: { in: ACTIONS }
  validates :description, :occurred_at, :symbol, :quantity, presence: true
  validate :valid_account_and_amounts

  def initialize(attributes = {})
    defaults = { kind: "buy", time_zone: "UTC", fee_eur: "0",
      funded_from_wallet: attributes[:account]&.accountable&.subtype == "exchange" }
    super(defaults.merge(attributes))
  end

  def save
    return false unless valid?
    price, source, quote_at = resolve_price
    return false if errors.any?

    account.with_lock do
      @entry = build_entry(symbol.to_s.upcase, signed_quantity, price, source, quote_at)
      @entry.save!
      if kind == "swap"
        received_price = number(quantity) * price / number(counter_quantity)
        build_entry(counter_symbol.to_s.upcase, number(counter_quantity), received_price, "manual_exchange_ratio", quote_at, secondary: true).save!
      end
    end
    account.sync_later
    true
  rescue Crypto::HistoricalQuote::UnavailableError => e
    errors.add(:base, e.message)
    false
  rescue ActiveRecord::RecordInvalid => e
    errors.add(:base, e.record.errors.full_messages.to_sentence)
    false
  end

  private

    def number(value)
      BigDecimal(value.to_s, exception: false)
    end

    def parsed_time
      @parsed_time ||= begin
        zone = Time.find_zone!(time_zone)
        raise ArgumentError unless zone
        parsed = zone.parse(occurred_at.to_s)
        raise ArgumentError unless parsed
        parsed
      end
    end

    def valid_account_and_amounts
      errors.add(:base, I18n.t("crypto_ledger.manual_only")) unless account&.crypto? && account.manual?
      errors.add(:symbol, :invalid) unless symbol.to_s.upcase.match?(Crypto::HistoricalQuote::SYMBOL)
      errors.add(:symbol, :invalid) if symbol.to_s.upcase == "EUR" && %w[buy sell swap].include?(kind)
      errors.add(:quantity, :invalid) unless number(quantity)&.finite? && number(quantity).positive?
      errors.add(:fee_eur, :invalid) unless number(fee_eur)&.finite? && number(fee_eur) >= 0
      %i[unit_price_eur value_eur].each do |field|
        value = public_send(field)
        errors.add(field, :invalid) if value.present? && !(number(value)&.finite? && number(value).positive?)
      end
      if kind == "swap"
        errors.add(:counter_symbol, :invalid) unless counter_symbol.to_s.upcase.match?(Crypto::HistoricalQuote::SYMBOL) && ![ symbol.to_s.upcase, "EUR" ].include?(counter_symbol.to_s.upcase)
        errors.add(:counter_quantity, :invalid) unless number(counter_quantity)&.finite? && number(counter_quantity).positive?
      end
      if balance_after.present? && !(number(balance_after)&.finite? && number(balance_after) >= 0)
        errors.add(:balance_after, :invalid)
      end
      errors.add(:occurred_at, :invalid) if parsed_time > Time.current
    rescue ArgumentError, TypeError
      errors.add(:occurred_at, :invalid)
    end

    def resolve_price
      if symbol.to_s.upcase == "EUR"
        if (unit_price_eur.present? && number(unit_price_eur) != 1) || (value_eur.present? && number(value_eur) != number(quantity))
          errors.add(:base, I18n.t("crypto_ledger.inconsistent_value"))
        end
        return [ 1.to_d, "eur", parsed_time ]
      end
      if ActiveModel::Type::Boolean.new.cast(suggested_price) && unit_price_eur.present?
        quote = Crypto::HistoricalQuote.fetch(symbol: symbol, at: parsed_time)
        if number(unit_price_eur) == quote.price
          if value_eur.present? && (quote.price * number(quantity) - number(value_eur)).abs > 0.01.to_d
            errors.add(:base, I18n.t("crypto_ledger.inconsistent_value"))
          end
          return [ quote.price, quote.source, quote.quoted_at ]
        end
      end
      if unit_price_eur.present? && value_eur.present?
        if (number(unit_price_eur) * number(quantity) - number(value_eur)).abs > 0.01.to_d
          errors.add(:base, I18n.t("crypto_ledger.inconsistent_value"))
        end
        [ number(unit_price_eur), "manual", nil ]
      elsif unit_price_eur.present?
        [ number(unit_price_eur), "manual", nil ]
      elsif value_eur.present?
        [ number(value_eur) / number(quantity), "manual", nil ]
      else
        quote = Crypto::HistoricalQuote.fetch(symbol: symbol, at: parsed_time)
        [ quote.price, quote.source, quote.quoted_at ]
      end
    end

    def signed_quantity
      %w[sell withdrawal swap].include?(kind) ? -number(quantity) : number(quantity)
    end

    def build_entry(asset, qty, price, source, quote_at, secondary: false)
      fee = secondary ? 0.to_d : number(fee_eur)
      amount = case kind
      when "buy", "sell" then wallet_funded? ? qty * price + fee : 0.to_d
      when "swap" then wallet_funded? ? fee : 0.to_d
      else asset == "EUR" ? -qty + fee : (wallet_funded? ? fee : 0.to_d)
      end
      metadata = {
        "occurred_at" => parsed_time.iso8601(6), "time_zone" => time_zone, "kind" => kind,
        "symbol" => asset, "quantity" => qty.to_s("F"), "unit_price_eur" => price.to_s("F"),
        "value_eur" => (qty * price).to_s("F"), "fee_eur" => fee.to_s("F"),
        "cash_delta_eur" => (-amount).to_s("F"), "price_source" => source, "quoted_at" => quote_at&.iso8601
      }
      metadata["balance_after"] = number(balance_after).to_s("F") if balance_after.present? && !secondary
      metadata["funded_from_wallet"] = wallet_funded?
      entryable = if asset == "EUR"
        Transaction.new(kind: "funds_movement", extra: { "crypto" => metadata })
      else
        security = Security.find_or_create_by!(ticker: "CRYPTO:#{asset}", exchange_operating_mic: nil) do |record|
          record.name = asset
          record.offline = true
        end
        label = { "buy" => "Buy", "sell" => "Sell", "swap" => "Exchange" }.fetch(kind, "Transfer")
        Trade.new(security: security, qty: qty, price: label == "Transfer" ? 0 : price,
          currency: "EUR", fee: fee, investment_activity_label: label, extra: { "crypto" => metadata })
      end
      account.entries.build(name: description, date: parsed_time.to_date, occurred_at: parsed_time,
        amount: amount, currency: "EUR", source: "manual_crypto", user_modified: true, entryable: entryable)
    end

    def wallet_funded?
      ActiveModel::Type::Boolean.new.cast(funded_from_wallet)
    end
end
