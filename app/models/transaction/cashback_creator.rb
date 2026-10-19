class Transaction::CashbackCreator
  attr_reader :parent_entry, :account, :family, :enabled, :value, :type, :idempotency_key

  def initialize(parent_entry:, account:, family:, enabled:, value:, type: "fixed", idempotency_key: nil)
    @parent_entry = parent_entry
    @account = account
    @family = family
    @enabled = enabled.in?([ true, "1", "true" ])
    @raw_value = value
    @value = value.to_s.tr(",", ".").to_d
    @type = type.presence || "fixed"
    @idempotency_key = idempotency_key
  end

  def enabled?
    @enabled
  end

  def valid?
    return true unless enabled?

    @raw_value.present? && @value.positive? && calculated_amount.positive?
  end

  def error_message
    I18n.t("transactions.cashback_amount_invalid", default: "L'importo del cashback deve essere maggiore di zero")
  end

  def calculated_amount
    @calculated_amount ||= if type == "percentage"
      (parent_entry.amount.to_d * (value / 100.to_d)).round(2)
    else
      value.round(2)
    end
  end

  def create
    return nil unless enabled? && valid?

    category = find_or_initialize_cashback_category

    # In Sure, outflows are positive, inflows (Entrata) are negative amounts
    inflow_amount = -calculated_amount.abs

    cashback_idempotency_key = "#{idempotency_key}-cashback" if idempotency_key.present?

    cashback_entry = account.entries.new(
      amount: inflow_amount,
      currency: parent_entry.currency,
      date: parent_entry.date,
      name: entry_name,
      user_modified: true,
      idempotency_key: cashback_idempotency_key,
      entryable: Transaction.new(category: category)
    )

    if cashback_entry.save
      cashback_entry.sync_account_later
      cashback_entry.lock_saved_attributes!
      cashback_entry.mark_user_modified!
      cashback_entry
    else
      cashback_entry
    end
  end

  private

  def find_or_initialize_cashback_category
    family.categories.find_by("LOWER(name) = ?", "cashback") ||
      family.categories.create!(
        name: "Cashback",
        color: "#22c55e",
        lucide_icon: "receipt"
      )
  end

  def entry_name
    if parent_entry.name.present?
      I18n.t("transactions.cashback_entry_name", default: "Cashback - %{name}", name: parent_entry.name)
    else
      "Cashback"
    end
  end
end
