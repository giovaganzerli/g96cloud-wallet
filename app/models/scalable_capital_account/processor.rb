class ScalableCapitalAccount::Processor
  def initialize(provider_account)
    @provider_account = provider_account
  end

  def process
    normalizer = Provider::ScalableCapital::Normalizer.new(@provider_account.raw_payload)
    # Validate the entire snapshot before touching canonical financial records.
    holdings = normalizer.holdings
    activities = normalizer.activities
    cash = normalizer.cash_balance
    account = @provider_account.account
    return if account.nil? || account.disabled? || account.pending_deletion?

    account.with_lock do
      adapter = Account::ProviderImportAdapter.new(account)
      holdings.each do |position|
        attrs = position.except(:isin, :name)
        security = resolve_security(position[:isin], position[:name])
        adapter.import_holding(
          **attrs, security: security, source: "scalable_capital",
          external_id: "scalable_capital_#{@provider_account.portfolio_id}_#{position[:isin]}_#{position[:date]}",
          account_provider_id: @provider_account.account_provider.id
        )
      end
      # An empty complete snapshot means no positions, not "keep yesterday's".
      close_missing_holdings(adapter, holdings)
      activities.each do |activity|
        attrs = activity.except(:kind, :isin, :security_name)
        existing = account.entries.find_by(source: "scalable_capital", external_id: activity[:external_id])
        next if existing&.protected_from_sync? && activity[:kind] == :trade

        if activity[:kind] == :trade
          adapter.import_trade(**attrs, security: resolve_security(activity[:isin], activity[:security_name]), source: "scalable_capital")
        else
          adapter.import_transaction(**attrs, source: "scalable_capital", allow_heuristic_matching: false)
        end
      end
      total = cash + holdings.sum { |position| position[:amount] }
      adapter.update_balance(balance: total, cash_balance: cash, source: "scalable_capital")
      account.set_current_balance(total)
    end
  end

  private

    def resolve_security(isin, name)
      # Sure's securities have no ISIN column, so the ISIN becomes the ticker
      # of an offline security. This mirrors the Trade Republic integration:
      # reuse an existing ISIN row instead of guessing a ticker, and never
      # overwrite a security another provider already resolved.
      existing = Security.find_by(ticker: isin)
      return existing if existing

      Security.create!(ticker: isin, name: name.presence || isin, offline: true, offline_reason: "scalable_capital_isin")
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      Security.find_by(ticker: isin)
    end

    def close_missing_holdings(adapter, positions)
      date = Date.iso8601(@provider_account.raw_payload.fetch("date"))
      present_ids = positions.map { |position| resolve_security(position[:isin], position[:name]).id }
      @provider_account.account.holdings
        .where(account_provider: @provider_account.account_provider)
        .where("date <= ?", date).where.not(security_id: present_ids)
        .select(:security_id).distinct.each do |holding|
          adapter.import_holding(
            security: holding.security, quantity: 0, amount: 0, price: 0,
            currency: "EUR", date: date, source: "scalable_capital",
            external_id: "scalable_capital_closed_#{holding.security_id}_#{date}",
            account_provider_id: @provider_account.account_provider.id
          )
        end
    end
end
