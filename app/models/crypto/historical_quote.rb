class Crypto::HistoricalQuote
  class UnavailableError < StandardError; end

  SYMBOL = /\A[A-Z0-9]{2,15}\z/

  def self.fetch(symbol:, at:)
    symbol = symbol.to_s.strip.upcase
    raise UnavailableError, I18n.t("crypto_ledger.quote_unavailable") unless symbol.match?(SYMBOL)
    if symbol == "EUR"
      return Provider::BinancePublic::IntradayPrice.new(price: 1.to_d, currency: "EUR",
        requested_at: at, quoted_at: at, source: "eur")
    end
    provider = Security.provider_for("binance_public")
    raise UnavailableError, I18n.t("crypto_ledger.provider_required") unless provider

    response = provider.fetch_security_price_at(symbol: "CRYPTO:#{symbol}EUR", timestamp: at)
    raise UnavailableError, I18n.t("crypto_ledger.quote_unavailable") unless response.success?
    response.data
  end
end
