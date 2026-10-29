class Transaction::RoundUpCreator
  # Mirrors Transaction::CashbackCreator: a manual expense on an account with
  # "Spiccioli" enabled can create a companion transfer that rounds the expense
  # up to the next whole currency unit, repeated by the configured multiplier.
  #
  # The client toggle is only a request. `enabled?` re-checks the account
  # configuration and the user's write access to the destination, so a tampered
  # form can never move money between accounts it does not own.
  attr_reader :parent_entry, :account, :family, :user, :idempotency_key

  def initialize(parent_entry:, account:, family: account.family, enabled:, idempotency_key: nil, user: Current.user)
    @parent_entry = parent_entry
    @account = account
    @family = family
    @user = user
    @enabled = enabled.in?([ true, "1", "true" ])
    @idempotency_key = idempotency_key
  end

  def enabled?
    @enabled && outflow? && account.round_ups_available_for?(user)
  end

  # Calculated in the account's currency, because the transfer legs are built
  # from the account, not from the entry. Same-currency entries short-circuit
  # inside Money#exchange_to.
  def calculated_amount
    @calculated_amount ||= begin
      amount = source_amount
      difference = amount.ceil - amount
      # An already round expense still rounds up: 2,00 € becomes 1,00 € (x the
      # multiplier), which is the behaviour the feature promises.
      difference = BigDecimal("1") if difference <= 0

      rounded = (difference * multiplier).round(precision)
      rounded = BigDecimal("1") if rounded <= 0
      rounded
    end
  end

  def create
    return nil unless enabled?

    setting = account.round_up_setting

    Transfer::Creator.new(
      family: family,
      source_account_id: account.id,
      destination_account_id: setting.destination_account_id,
      date: parent_entry.date,
      amount: calculated_amount,
      idempotency_key: idempotency_key.present? ? "#{idempotency_key}-roundup" : nil,
      outflow_name: I18n.t("transactions.round_up.outflow_name", destination: setting.destination_account.name),
      inflow_name: I18n.t("transactions.round_up.inflow_name", source: account.name)
    ).create
  end

  private
    # Only expenses move spare change into savings. Inflows and trade/valuation
    # entries never reach here (the form hides the toggle), but the creator is
    # the authoritative guard.
    def outflow?
      parent_entry.amount.to_d.positive?
    end

    def multiplier
      account.round_up_setting.multiplier
    end

    def source_amount
      @source_amount ||= Money.new(parent_entry.amount.to_d.abs, parent_entry.currency)
                              .exchange_to(account.currency, date: parent_entry.date)
                              .amount
    end

    def precision
      Money::Currency.new(account.currency).default_precision
    end
end
