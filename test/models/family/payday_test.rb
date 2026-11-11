require "test_helper"

class Family::PaydayTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @tag = tags(:one)
    @family.update!(payday_tag: @tag)
  end

  test "payday dates are the income transactions carrying the payday tag" do
    create_payday(date: Date.new(2026, 10, 28))
    create_payday(date: Date.new(2026, 10, 15), amount: 50, name: "Refund")

    assert_equal [ Date.new(2026, 10, 28) ], @family.payday_dates
  end

  test "a tagged outflow is not a payday" do
    create_payday(date: Date.new(2026, 10, 28), amount: 2000, name: "Bonus")

    assert_empty @family.payday_dates
    assert_not @family.payday_anchored?
  end

  test "an investment contribution is not a payday even though it is a negative amount" do
    create_payday(date: Date.new(2026, 10, 28), amount: -500, name: "Contribution", kind: "investment_contribution")

    assert_empty @family.payday_dates
  end

  test "the month runs from a payday to the day before the next one" do
    create_payday(date: Date.new(2026, 10, 28))
    create_payday(date: Date.new(2026, 11, 28))

    assert_equal Date.new(2026, 10, 28), @family.custom_month_start_for(Date.new(2026, 11, 15))
    assert_equal Date.new(2026, 11, 27), @family.custom_month_end_for(Date.new(2026, 11, 15))
  end

  test "a payday that moves later in the month moves the month boundary with it" do
    create_payday(date: Date.new(2026, 10, 28))
    create_payday(date: Date.new(2026, 11, 30))

    assert_equal Date.new(2026, 10, 28), @family.custom_month_start_for(Date.new(2026, 11, 15))
    assert_equal Date.new(2026, 11, 29), @family.custom_month_end_for(Date.new(2026, 11, 15))
  end

  test "the month in progress ends one day before the estimated next payday" do
    create_payday(date: Date.new(2026, 10, 28))

    # No November payday recorded yet: the month still has an end.
    assert_equal Date.new(2026, 11, 27), @family.custom_month_end_for(Date.new(2026, 11, 15))
  end

  test "the estimated next payday is clamped to the last day of a shorter month" do
    create_payday(date: Date.new(2026, 1, 31))

    # February 2026 has 28 days, so the payday after the 31st lands on the 28th.
    assert_equal Date.new(2026, 2, 27), @family.custom_month_end_for(Date.new(2026, 2, 10))
  end

  test "the month starts a month before the first payday recorded when the date precedes them all" do
    create_payday(date: Date.new(2026, 10, 28))

    assert_equal Date.new(2026, 9, 28), @family.custom_month_start_for(Date.new(2026, 9, 10))
  end

  test "the month start follows the payday tag even when the fixed start day is the 1st" do
    create_payday(date: Date.new(2026, 10, 28))

    assert @family.uses_custom_month_start?
  end

  test "without a payday tag the fixed start day still rules" do
    @family.update!(payday_tag: nil)
    @family.update!(month_start_day: 15)

    assert @family.uses_custom_month_start?
    assert_equal Date.new(2026, 11, 15), @family.custom_month_start_for(Date.new(2026, 11, 20))
  end

  test "the payday tag must belong to the family" do
    other_family = families(:empty)
    other_tag = other_family.tags.create!(name: "Other payday", color: Tag::COLORS.first)

    @family.payday_tag = other_tag

    assert_not @family.valid?
    assert_includes @family.errors[:payday_tag], I18n.t("errors.messages.invalid")
  end

  test "current_custom_month_period covers the month the payday falls in" do
    create_payday(date: Date.new(2026, 10, 28))
    create_payday(date: Date.new(2026, 11, 28))

    travel_to Date.new(2026, 11, 15) do
      period = @family.current_custom_month_period

      assert_equal Date.new(2026, 10, 28), period.start_date
      assert_equal Date.new(2026, 11, 27), period.end_date
    end
  end

  test "the current month period the dashboard reads follows the payday" do
    create_payday(date: Date.new(2026, 10, 28))
    create_payday(date: Date.new(2026, 11, 28))

    travel_to Date.new(2026, 11, 15) do
      period = Period.current_month_for(@family)

      assert_equal "current_month", period.key
      assert_equal Date.new(2026, 10, 28), period.start_date
      assert_equal Date.new(2026, 11, 27), period.end_date
    end
  end

  private
    def create_payday(date:, amount: -2000, name: "Salary", kind: nil)
      attributes = { name: name, date: date, amount: amount }
      attributes[:kind] = kind if kind
      entry = create_transaction(**attributes)
      entry.entryable.update!(tag_ids: [ @tag.id ])
      entry
    end
end
