require "test_helper"

class Budget::PaydayTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @tag = @family.tags.create!(name: "Payday", color: Tag::COLORS.first)
    @family.update!(payday_tag: @tag)
  end

  test "the budget period starts on the payday and ends the day before the next one" do
    create_payday(Date.new(2026, 10, 28))
    create_payday(Date.new(2026, 11, 28))

    budget = Budget.find_or_bootstrap(@family, start_date: Date.new(2026, 11, 15), user: @user)

    assert_equal Date.new(2026, 10, 28), budget.start_date
    assert_equal Date.new(2026, 11, 27), budget.end_date
  end

  test "the budget spends what happened inside the payday month" do
    create_payday(Date.new(2026, 10, 28))
    create_payday(Date.new(2026, 11, 28))

    account = @family.accounts.first
    category = @family.categories.create!(name: "Groceries", color: Tag::COLORS.first)
    create_transaction(account: account, name: "Before the payday", date: Date.new(2026, 10, 27), amount: 100, category: category)
    create_transaction(account: account, name: "Inside the month", date: Date.new(2026, 11, 10), amount: 50, category: category)

    budget = Budget.find_or_bootstrap(@family, start_date: Date.new(2026, 11, 15), user: @user)
    budget_category = budget.budget_categories.find_by(category: category) ||
      budget.budget_categories.create!(category: category, budgeted_spending: 0, currency: "USD")

    assert_equal 50, budget_category.actual_spending.to_d
  end

  test "the budget slug round-trips through the payday month" do
    create_payday(Date.new(2026, 10, 28))
    create_payday(Date.new(2026, 11, 28))

    budget = Budget.find_or_bootstrap(@family, start_date: Date.new(2026, 11, 15), user: @user)
    slug = Budget.date_to_param(budget.start_date)

    assert_equal budget.start_date, Budget.param_to_date(slug, family: @family)
  end

  test "the budget is named after the range it covers" do
    create_payday(Date.new(2026, 10, 28))
    create_payday(Date.new(2026, 11, 28))

    budget = Budget.find_or_bootstrap(@family, start_date: Date.new(2026, 11, 15), user: @user)

    assert_includes budget.name, I18n.l(Date.new(2026, 10, 28), format: :short)
  end

  test "a family without a payday label keeps the calendar month" do
    @family.update!(payday_tag: nil)

    budget = Budget.find_or_bootstrap(@family, start_date: Date.new(2026, 11, 15), user: @user)

    assert_equal Date.new(2026, 11, 1), budget.start_date
    assert_equal Date.new(2026, 11, 30), budget.end_date
  end

  private
    def create_payday(date)
      entry = create_transaction(account: @family.accounts.first, name: "Salary", date: date, amount: -2000)
      entry.entryable.update!(tag_ids: [ @tag.id ])
      entry
    end
end
