require "application_system_test_case"

class ChartPeriodPickerTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
  end

  # The portfolio and dashboard charts offer four calendar granularities plus
  # the whole history, named in plain words instead of every period the app
  # knows about.
  test "the dashboard offers the calendar granularities and the whole history" do
    sign_in @user

    visit root_path
    open_period_picker

    assert_equal 6, period_options.size
    assert_equal [ "Day", "Week", "Month", "Year", "All", "Custom range" ], period_options.map(&:text)
  end

  test "the portfolio chart offers the calendar granularities and the whole history" do
    sign_in @user

    visit account_url(@account)
    open_period_picker

    assert_equal [ "Day", "Week", "Month", "Year", "All", "Custom range" ], period_options.map(&:text)
  end

  # A period saved before the picker was simplified still names a granularity,
  # so the trigger never shows a label the menu does not offer.
  test "a period saved before the simplification names the granularity it falls into" do
    sign_in @user
    @user.update!(default_period: "last_7_days")

    visit root_path

    assert_selector "button[aria-label='Time period: Week']"
  end

  # The same range a drag across the chart produces, entered as two dates.
  test "a custom range can be entered as dates" do
    sign_in @user

    visit account_url(@account)
    find("button[aria-label^='Time period:']").click
    find("a[data-custom-range]").click

    within "dialog[open]" do
      # The browser renders a native date input in its own locale's format.
      fill_in I18n.t("period_ranges.new.start_date"), with: "09/01/2026"
      fill_in I18n.t("period_ranges.new.end_date"), with: "09/30/2026"
      click_button I18n.t("period_ranges.new.apply")
    end

    assert_current_path(%r{/accounts/#{@account.id}\?.*start_date=2026-09-01.*end_date=2026-09-30})
  end

  test "a custom range can be entered from the dashboard" do
    sign_in @user

    visit root_path
    find("button[aria-label^='Time period:']").click
    find("a[data-custom-range]").click

    within "dialog[open]" do
      fill_in I18n.t("period_ranges.new.start_date"), with: "09/01/2026"
      fill_in I18n.t("period_ranges.new.end_date"), with: "09/30/2026"
      click_button I18n.t("period_ranges.new.apply")
    end

    assert_current_path(%r{\A/\?.*start_date=2026-09-01.*end_date=2026-09-30})
  end

  private
    def open_period_picker
      find("button[aria-label^='Time period:']").click
    end

    def period_options
      page.all("a[role='menuitemradio']")
    end
end
