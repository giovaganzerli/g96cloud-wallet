class BitpandaItem::Syncer
  def initialize(item)
    @item = item
  end

  def perform_sync(sync)
    return if @item.scheduled_for_deletion?

    snapshot = @item.provider.snapshot
    normalizer = Provider::Bitpanda::Normalizer.new(snapshot)
    normalizer.positions
    normalizer.activities
    normalizer.date

    @item.with_lock do
      return if @item.scheduled_for_deletion?

      provider_account = @item.bitpanda_accounts.find_or_initialize_by(account_id: "portfolio")
      provider_account.update!(name: @item.name, currency: "EUR", raw_payload: snapshot)
      unless provider_account.account_provider
        account = @item.family.accounts.create!(
          name: @item.name, currency: "EUR", balance: 0, accountable: Crypto.new(subtype: "exchange")
        )
        account.auto_share_with_family! if @item.family.share_all_by_default?
        provider_account.create_account_provider!(account: account)
        provider_account.reload
      end
      BitpandaAccount::Processor.new(provider_account).process
      @item.update!(status: :good)
    end

    if @item.review_required?
      DebugLogEntry.capture(
        category: "provider_sync_error", level: "warn",
        message: "Bitpanda balance corrections imported with classification pending review",
        source: self.class.name, provider_key: "bitpanda", family: @item.family,
        account_provider: @item.bitpanda_accounts.first&.account_provider,
        metadata: { bitpanda_item_id: @item.id, operation_types: Provider::Bitpanda::Normalizer::REVIEW_REQUIRED_TYPES }
      )
    end

    @item.accounts.visible.each do |account|
      account.sync_later(parent_sync: sync, window_start_date: sync.window_start_date, window_end_date: sync.window_end_date)
    end
  rescue Provider::Bitpanda::AuthenticationError
    @item.update!(status: :requires_update)
    capture_failure("Bitpanda API key is invalid or lacks read permissions")
    raise
  rescue StandardError => e
    capture_failure("Bitpanda synchronization failed", error_class: e.class.name,
      reason: e.is_a?(Provider::Bitpanda::Error) ? e.message : nil)
    raise
  end

  def perform_post_sync
  end

  private

    def capture_failure(message, **metadata)
      DebugLogEntry.capture(
        category: "provider_sync_error", level: "error", message: message,
        source: self.class.name, provider_key: "bitpanda", family: @item.family,
        account_provider: @item.bitpanda_accounts.first&.account_provider,
        metadata: metadata.merge(bitpanda_item_id: @item.id)
      )
    end
end
