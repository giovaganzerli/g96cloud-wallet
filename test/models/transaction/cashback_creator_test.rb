require "test_helper"

class Transaction::CashbackCreatorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @entry = @account.entries.create!(
      name: "Supermarket Purchase",
      amount: 150.00,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )
  end

  test "creates fixed amount cashback entry" do
    creator = Transaction::CashbackCreator.new(
      parent_entry: @entry,
      account: @account,
      family: @family,
      enabled: true,
      value: "5.50",
      type: "fixed"
    )

    assert creator.enabled?
    assert creator.valid?
    assert_equal 5.50, creator.calculated_amount

    cashback_entry = creator.create
    assert cashback_entry.persisted?
    assert_equal(-5.50, cashback_entry.amount)
    assert_equal "USD", cashback_entry.currency
    assert_equal @entry.date, cashback_entry.date
    assert_equal "Cashback - Supermarket Purchase", cashback_entry.name
    assert_equal "Cashback", cashback_entry.transaction.category.name
    assert cashback_entry.user_modified?
  end

  test "creates percentage cashback entry" do
    creator = Transaction::CashbackCreator.new(
      parent_entry: @entry,
      account: @account,
      family: @family,
      enabled: true,
      value: "10",
      type: "percentage"
    )

    assert creator.enabled?
    assert creator.valid?
    assert_equal 15.00, creator.calculated_amount

    cashback_entry = creator.create
    assert cashback_entry.persisted?
    assert_equal(-15.00, cashback_entry.amount)
    assert_equal "Cashback - Supermarket Purchase", cashback_entry.name
  end

  test "uses existing Cashback category if present" do
    existing_category = @family.categories.create!(
      name: "Cashback",
      color: "#3b82f6",
      lucide_icon: "receipt"
    )

    creator = Transaction::CashbackCreator.new(
      parent_entry: @entry,
      account: @account,
      family: @family,
      enabled: true,
      value: "2.00",
      type: "fixed"
    )

    cashback_entry = creator.create
    assert_equal existing_category.id, cashback_entry.transaction.category_id
  end

  test "validates cashback amount" do
    invalid_creator = Transaction::CashbackCreator.new(
      parent_entry: @entry,
      account: @account,
      family: @family,
      enabled: true,
      value: "0",
      type: "fixed"
    )

    assert invalid_creator.enabled?
    assert_not invalid_creator.valid?
    assert_nil invalid_creator.create
  end

  test "does nothing when disabled" do
    disabled_creator = Transaction::CashbackCreator.new(
      parent_entry: @entry,
      account: @account,
      family: @family,
      enabled: false,
      value: "10",
      type: "fixed"
    )

    assert_not disabled_creator.enabled?
    assert_nil disabled_creator.create
  end
end
