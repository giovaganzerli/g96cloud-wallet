# Shared helpers for holding calculators (ForwardCalculator / ReverseCalculator).
# Expects the including class to expose an `account` reader.
module Holding::TradeCalculatorHelpers
  private
    # Converts a trade's price into the account's currency, falling back to the
    # raw price when no exchange rate is available.
    def converted_trade_price(trade)
      Money.new(trade.price, trade.currency).exchange_to(account.currency).amount
    rescue Money::ConversionError
      trade.price
    end

    # Prices a trade for cost-basis tracking. Ordinary trades use their executed
    # price; inbound transfers carrying an estimated cost basis use the
    # exact-date market quote the importer recorded, never the zero price kept
    # on the movement itself.
    def cost_basis_price(trade)
      estimate = trade.estimated_cost_basis_price
      return converted_trade_price(trade) if estimate.blank?

      currency = trade.estimated_cost_basis_currency.presence || trade.currency
      Money.new(estimate.to_d, currency).exchange_to(account.currency).amount
    rescue Money::ConversionError
      estimate.to_d
    end
end
