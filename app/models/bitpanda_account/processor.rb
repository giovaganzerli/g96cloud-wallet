class BitpandaAccount::Processor
  CRYPTO_ASSET_TYPES = %w[crypto cryptocoin].freeze

  def initialize(provider_account)
    @provider_account = provider_account
  end

  def process
    account = @provider_account.account
    return if account.nil? || account.disabled? || account.pending_deletion?

    normalizer = Provider::Bitpanda::Normalizer.new(@provider_account.raw_payload)
    positions = normalizer.positions
    activities = normalizer.activities
    date = normalizer.date

    account.with_lock do
      adapter = Account::ProviderImportAdapter.new(account)
      positions.select { |position| position[:asset] }.each do |position|
        security = resolve_security(position[:id], position[:symbol], position[:name], position[:type])
        quantity = position[:quantity]
        adapter.import_holding(
          security: security, quantity: quantity, amount: position[:amount],
          price: quantity.zero? ? 0 : position[:amount] / quantity,
          currency: "EUR", date: date, source: "bitpanda",
          external_id: "bitpanda_#{position[:id]}_#{date}",
          account_provider_id: @provider_account.account_provider.id
        )
      end
      close_missing_holdings(adapter, positions, date)
      activities.each { |activity| import_activity(adapter, account, activity) }

      total = positions.sum { |position| position[:amount] }
      cash = positions.reject { |position| position[:asset] }.sum { |position| position[:amount] }
      adapter.update_balance(balance: total, cash_balance: cash, source: "bitpanda")
      account.set_current_balance(total, date: date, schedule_sync: false)
    end
  end

  private

    def import_activity(adapter, account, activity)
      attrs = activity.slice(:external_id, :currency, :date, :amount)
      label = if activity[:metadata]["review_required"]
        I18n.t("bitpanda_items.activity_names.#{activity[:metadata].fetch('operation_type').downcase}")
      else
        activity[:label]
      end
      name = "#{label} #{activity[:quantity].to_d.abs.to_s('F')} #{activity[:symbol]}"
      if activity[:asset]
        existing = account.entries.find_by(source: "bitpanda", external_id: activity[:external_id])
        return if existing&.protected_from_sync?

        retire_legacy_cash_counterpart(account, activity)

        security = resolve_security(activity[:asset_id], activity[:symbol], activity[:security_name], activity[:asset_type])
        price = activity[:price]
        if price.nil? && activity[:label] != "Transfer"
          quote = security.find_or_fetch_price(date: activity[:date])
          unless quote && quote.date == activity[:date] && quote.price.to_d.positive?
            raise Provider::Bitpanda::InvalidDataError, "Historical price missing for #{activity[:symbol]} on #{activity[:date]}; no estimated amount was imported"
          end
          price = quote.price
          attrs[:currency] = quote.currency
          # Asset-only movements have no cash leg; their market valuation
          # belongs to holdings, not a synthetic cash transaction.
        end

        # Inbound crypto transfers carry no execution price, so their cost basis
        # is genuinely unknown. Record the exact-date market quote instead,
        # strictly for cost-basis purposes: the movement keeps a zero price and
        # zero cash effect, and the UI labels the resulting basis as estimated.
        # Review-required corrections are never valued this way.
        estimate_allowed = price.nil? && activity[:label] == "Transfer" &&
          activity[:quantity].positive? && !activity[:metadata]["review_required"] &&
          CRYPTO_ASSET_TYPES.include?(activity[:asset_type].to_s.downcase)
        estimate = estimate_allowed ? inbound_transfer_estimate(security, activity) : nil

        entry = adapter.import_trade(
          **attrs, security: security, quantity: activity[:quantity], price: price || 0,
          name: name, activity_label: activity[:label], fee: activity[:fee], source: "bitpanda"
        )

        extra = entry.trade.extra.to_h.merge("bitpanda" => activity[:metadata])
        existing_estimate = extra.dig("cost_basis", "estimated_price").present?
        if estimate
          extra["cost_basis"] = {
            "estimated_price" => estimate.price.to_d.to_s("F"),
            "estimated_currency" => estimate.currency,
            "estimated_on" => activity[:date].iso8601,
            "estimated_source" => "market_quote_at_deposit"
          }
        elsif !(estimate_allowed && existing_estimate)
          extra.delete("cost_basis")
        end

        extra["bitpanda"] = extra["bitpanda"].merge(
          "cost_basis_unknown" => price.nil? && extra.dig("cost_basis", "estimated_price").blank?
        )
        entry.trade.update!(extra: extra)

        if estimate_allowed && estimate.nil? && !existing_estimate
          DebugLogEntry.capture(
            category: "provider_sync_warning", level: "warn",
            message: "Inbound crypto transfer has no exact-date market quote; cost basis remains unknown",
            source: self.class.name, provider_key: "bitpanda", family: account.family,
            account_provider: @provider_account.account_provider,
            metadata: { symbol: activity[:symbol], date: activity[:date].iso8601 }
          )
        end
      else
        entry = adapter.import_transaction(
          **attrs, name: name, source: "bitpanda", investment_activity_label: activity[:label],
          kind: %w[Transfer Exchange].include?(activity[:label]) ? "funds_movement" : "standard",
          extra: { "bitpanda" => activity[:metadata] }, replace_extra_namespaces: [ "bitpanda" ],
          allow_heuristic_matching: false
        )
      end
      unless entry.protected_from_sync?
        entry.update!(occurred_at: Time.iso8601(activity[:metadata].fetch("transaction").fetch("credited_at")))
      end
    end

    def retire_legacy_cash_counterpart(account, activity)
      id = activity[:metadata]["cash_transaction_id"]
      return unless id
      entry = account.entries.find_by(source: "bitpanda", external_id: "bitpanda_#{id}")
      return unless entry && !entry.excluded?
      unless entry.transaction? && !entry.protected_from_sync?
        raise Provider::Bitpanda::InvalidDataError, I18n.t("crypto_ledger.edited_counterpart")
      end
      entry.update!(excluded: true)
      DebugLogEntry.capture(category: "provider_sync_error", level: "warn",
        message: "Legacy fiat counterpart excluded after grouping Bitpanda trade legs",
        source: self.class.name, provider_key: "bitpanda", family: account.family,
        account_provider: @provider_account.account_provider, metadata: { entry_id: entry.id })
    end

    def resolve_security(id, symbol, name, type)
      @securities ||= {}
      @securities[id] ||= begin
        # Never equate stocks, metals or indices with a crypto of the same symbol.
        crypto = CRYPTO_ASSET_TYPES.include?(type.to_s.downcase)
        ticker = (crypto ? "CRYPTO:#{symbol}" : "BITPANDA:#{id}").upcase
        security = Security.find_or_initialize_by(ticker: ticker, exchange_operating_mic: nil)
        if security.new_record? && crypto
          # Only accept the exact base asset (optionally a quoted pair), never
          # the generic resolver's fuzzy "closest" crypto ticker.
          pattern = /\A(?:CRYPTO:)?#{Regexp.escape(symbol)}(?:USD|USDT|USDC|EUR|GBP)?\z/i
          match = Security.search_provider(ticker).find { |candidate| candidate.ticker&.match?(pattern) }
          if match
            security = Security::Resolver.new(
              match.ticker, exchange_operating_mic: match.exchange_operating_mic,
              country_code: match.country_code, price_provider: match.price_provider
            ).resolve
          end
        end
        security.tap do |record|
          if record.new_record?
            record.assign_attributes(name: name, offline: true, offline_reason: "bitpanda_asset")
            record.save!
          end
        end
      end
    end

    # Best-effort exact-date quote for an inbound crypto transfer. Failure to
    # find one leaves the cost basis unknown rather than failing the whole sync;
    # a warning entry records the gap for support.
    def inbound_transfer_estimate(security, activity)
      quote = security.find_or_fetch_price(date: activity[:date])
      return unless quote && quote.date == activity[:date] && quote.price.to_d.positive?

      quote
    rescue => e
      Rails.logger.warn("Bitpanda inbound transfer quote failed for #{activity[:symbol]} on #{activity[:date]}: #{e.class}")
      nil
    end

    def close_missing_holdings(adapter, positions, date)
      ids = positions.select { |position| position[:asset] }.map do |position|
        resolve_security(position[:id], position[:symbol], position[:name], position[:type]).id
      end
      @provider_account.account.holdings.where(account_provider: @provider_account.account_provider)
        .where("date <= ?", date).where.not(security_id: ids).select(:security_id).distinct.each do |holding|
          adapter.import_holding(
            security: holding.security, quantity: 0, amount: 0, price: 0,
            currency: "EUR", date: date, source: "bitpanda",
            external_id: "bitpanda_closed_#{holding.security_id}_#{date}",
            account_provider_id: @provider_account.account_provider.id
          )
        end
    end
end
