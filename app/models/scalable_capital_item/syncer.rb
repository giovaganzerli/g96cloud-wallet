class ScalableCapitalItem::Syncer
  def initialize(item)
    @item = item
  end

  def perform_sync(sync)
    return if @item.scheduled_for_deletion?

    # The CLI call is serialized by the session lock, not by a database row
    # lock: holding a row lock across a multi-minute network call would block
    # every other write to this connection, including the status update a
    # failed sync performs.
    existing = @item.scalable_capital_accounts.first
    snapshot = @item.provider.snapshot(portfolio_id: existing&.portfolio_id)
    overview = snapshot.fetch("overview")

    @item.with_lock do
      @item.class.transaction do
        provider_account = @item.scalable_capital_accounts.find_or_initialize_by(portfolio_id: overview.fetch("portfolio_id"))
        if provider_account.persisted? && provider_account.provider_account_id != overview.fetch("account_id")
          raise Provider::ScalableCapital::InvalidDataError, "Scalable Capital account identity changed"
        end
        provider_account.update!(
          provider_account_id: overview.fetch("account_id"), name: @item.name,
          currency: "EUR", raw_payload: snapshot
        )
        unless provider_account.account_provider
          account = @item.family.accounts.create!(name: @item.name, currency: "EUR", balance: 0, accountable: Investment.new)
          account.auto_share_with_family! if @item.family.share_all_by_default?
          provider_account.create_account_provider!(account: account)
          provider_account.reload
        end
        ScalableCapitalAccount::Processor.new(provider_account).process
        @item.update!(status: :good)
      end
    end

    @item.accounts.visible.each do |account|
      account.sync_later(parent_sync: sync, window_start_date: sync.window_start_date, window_end_date: sync.window_end_date)
    end
  rescue Provider::ScalableCapital::AuthenticationError, Provider::ScalableCapital::ConfigurationError
    @item.update!(status: :requires_update)
    capture_failure("Scalable Capital authorization or CLI setup is required")
    raise
  rescue StandardError => e
    reason = e.message if e.is_a?(Provider::ScalableCapital::Error)
    capture_failure("Scalable Capital synchronization failed", error_class: e.class.name, reason: reason)
    raise
  end

  def perform_post_sync
  end

  private

    def capture_failure(message, **metadata)
      DebugLogEntry.capture(
        category: "sync", level: "error", message: message,
        source: "scalable_capital", provider_key: "scalable_capital", family: @item.family,
        account_provider: @item.scalable_capital_accounts.first&.account_provider,
        metadata: metadata.merge(scalable_capital_item_id: @item.id)
      )
    end
end
