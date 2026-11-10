require "test_helper"

class UI::PeriodPickerTest < ViewComponent::TestCase
  test "renders one menuitemradio link per chart period, all carrying the period param and target frame" do
    render_inline(UI::PeriodPicker.new(selected: "current_month", url: "/", frame: "dashboard_sections"))

    links = page.all("a[role='menuitemradio']:not([data-custom-range])")
    assert_equal Period.chart_period_options.size, links.size

    links.each do |link|
      assert_match(/period=/, link[:href])
      assert_equal "dashboard_sections", link["data-turbo-frame"]
    end
  end

  test "offers the calendar granularities and the whole history with plain names" do
    render_inline(UI::PeriodPicker.new(selected: "current_month", url: "/"))

    rendered = page.all("a[role='menuitemradio']:not([data-custom-range])").map { |link| [ link[:href][/period=(\w+)/, 1], link.text.strip ] }
    assert_equal [ [ "last_day", "Day" ], [ "current_week", "Week" ], [ "current_month", "Month" ], [ "current_year", "Year" ], [ "all_time", "All" ] ], rendered
  end

  test "marks the selected period with aria-checked and a check glyph" do
    render_inline(UI::PeriodPicker.new(selected: "current_year", url: "/", frame: "dashboard_sections"))

    selected = page.all("a[role='menuitemradio'][aria-checked='true']")
    assert_equal 1, selected.size
    assert_match(/period=current_year/, selected.first[:href])
    # Check icon (svg) renders inside the selected item only.
    assert_selector "a[aria-checked='true'] svg"
  end

  test "trigger button shows the selected granularity's name" do
    render_inline(UI::PeriodPicker.new(selected: "current_month", url: "/"))

    assert_text "Month"
  end

  test "trigger accessible name announces the selected period" do
    render_inline(UI::PeriodPicker.new(selected: "current_year", url: "/"))

    assert_selector "button[aria-label='Time period: Year']"
  end

  test "trigger accessible name follows the locale" do
    I18n.with_locale(:de) do
      render_inline(UI::PeriodPicker.new(selected: "current_year", url: "/"))

      assert_selector "button[aria-label='Zeitraum: Jahr']"
    end
  end

  test "a period saved before the picker was simplified names the granularity it falls into" do
    render_inline(UI::PeriodPicker.new(selected: "last_7_days", url: "/"))

    assert_text "Week"
  end

  test "extra_params are merged into every option href" do
    render_inline(UI::PeriodPicker.new(
      selected: "last_30_days",
      url: "/accounts/abc",
      extra_params: { chart_view: "balance" }
    ))

    href = page.first("a[role='menuitemradio']")[:href]
    assert_match(%r{\A/accounts/abc\?}, href)
    assert_match(/chart_view=balance/, href)
    assert_match(/period=/, href)
  end

  test "accepts a Period object as selected" do
    render_inline(UI::PeriodPicker.new(selected: Period.current_month, url: "/"))

    assert_text "Month"
    assert_equal 1, page.all("a[aria-checked='true']").size
  end

  test "trigger shows a custom range's dates rather than falling back to a preset label" do
    custom_period = Period.custom(start_date: 15.days.ago.to_date, end_date: Date.current)

    render_inline(UI::PeriodPicker.new(selected: custom_period, url: "/"))

    assert_selector "button[aria-label='Time period: #{custom_period.label_range}']"
  end

  test "a custom range adds a trailing checked row so the list still has one selection" do
    custom_period = Period.custom(start_date: 15.days.ago.to_date, end_date: Date.current)

    render_inline(UI::PeriodPicker.new(selected: custom_period, url: "/"))

    links = page.all("a[role='menuitemradio']")
    assert_equal Period.chart_period_options.size + 1, links.size
    assert_equal custom_period.label_short, links.last.text.strip

    checked = page.all("a[role='menuitemradio'][aria-checked='true']")
    assert_equal 1, checked.size
    # The row opens the modal that edits the range, so it carries the target
    # path rather than the range itself.
    assert_match(/period_range/, checked.first[:href])
  end

  test "the custom row opens the range dialog and is offered without a custom range" do
    render_inline(UI::PeriodPicker.new(selected: Period.current_month, url: "/accounts/abc"))

    custom_row = page.all("a[role='menuitemradio']").last

    assert_equal "Custom range", custom_row.text.strip
    assert_match(/period_range/, custom_row[:href])
    assert_match(/url=%2Faccounts%2Fabc/, custom_row[:href])
    # The dialog is a modal frame, so the row does not navigate the chart frame.
    assert_equal "modal", custom_row["data-turbo-frame"]
  end

  test "a preset selection renders the custom row unchecked" do
    render_inline(UI::PeriodPicker.new(selected: Period.current_month, url: "/"))

    assert_equal Period.chart_period_options.size + 1, page.all("a[role='menuitemradio']").size
    assert_equal 1, page.all("a[role='menuitemradio'][aria-checked='true']").size
  end

  test "framed options advance the URL so a preset pick clears a stale custom range" do
    render_inline(UI::PeriodPicker.new(selected: Period.current_month, url: "/", frame: "dashboard_sections"))

    links = page.all("a[role='menuitemradio'][aria-checked='false']:not([data-custom-range])")
    assert links.any?
    links.each { |link| assert_equal "advance", link["data-turbo-action"] }
  end

  test "options advance the URL without an explicit frame too" do
    # The account page renders its picker inside the account's own container
    # frame, so those links are frame navigations as well and need the same
    # address-bar update. The custom-range row opens a modal instead.
    render_inline(UI::PeriodPicker.new(selected: Period.current_month, url: "/"))

    links = page.all("a[role='menuitemradio'][aria-checked='false']:not([data-custom-range])")
    assert links.any?
    links.each { |link| assert_equal "advance", link["data-turbo-action"] }
  end

  test "re-picking the checked preset replaces instead of stacking a history entry" do
    render_inline(UI::PeriodPicker.new(selected: Period.current_month, url: "/", frame: "dashboard_sections"))

    checked = page.all("a[role='menuitemradio'][aria-checked='true']")
    assert_equal 1, checked.size
    # Selecting the active row is a no-op; advancing would make Back a no-op too.
    assert_equal "replace", checked.first["data-turbo-action"]
  end

  test "leaving a custom range for a preset advances the URL" do
    custom_period = Period.custom(start_date: 15.days.ago.to_date, end_date: Date.current)

    render_inline(UI::PeriodPicker.new(selected: custom_period, url: "/"))

    links = page.all("a[role='menuitemradio']")
    # Leaving the custom range for a preset is a real change, so it still advances
    # and stays reachable with Back — the drag-select that set it advanced too.
    assert_equal "advance", links.first["data-turbo-action"]
  end

  # The loan chart offers its own timescales under the shared period keys.
  LOAN_OPTIONS = [ [ "current_month", "M" ], [ "last_5_years", "5Y" ], [ "all_time", "All" ] ].freeze

  test "options narrow the menu to their pairs, labelled from the options" do
    render_inline(UI::PeriodPicker.new(selected: "last_5_years", url: "/accounts/abc", options: LOAN_OPTIONS))

    links = page.all("a[role='menuitemradio']")
    assert_equal LOAN_OPTIONS.size, links.size
    LOAN_OPTIONS.zip(links).each do |(key, label), link|
      assert_match(/period=#{key}/, link[:href])
      assert_equal label, link.text.strip
    end
    assert_no_selector "a[href*='period=last_30_days']"

    checked = page.all("a[role='menuitemradio'][aria-checked='true']")
    assert_equal 1, checked.size
    assert_equal "replace", checked.first["data-turbo-action"]
    assert_selector "a[role='menuitemradio'][aria-checked='false'][data-turbo-action='advance']", count: LOAN_OPTIONS.size - 1
  end

  test "with options the trigger shows the option's label for the selected key" do
    # A label no Period uses, so the assertion cannot pass on Period's own label.
    options = [ [ "last_5_years", "Five years" ], [ "all_time", "Whole life" ] ]
    assert_not_equal "Five years", Period.from_key("last_5_years").label_short

    render_inline(UI::PeriodPicker.new(selected: "last_5_years", url: "/", options: options))

    assert_selector "button[aria-label='Time period: Five years']"
  end

  test "options leave out the custom range row" do
    custom_period = Period.custom(start_date: 15.days.ago.to_date, end_date: Date.current)

    render_inline(UI::PeriodPicker.new(selected: custom_period, url: "/", options: LOAN_OPTIONS))

    assert_equal LOAN_OPTIONS.size, page.all("a[role='menuitemradio']").size
    assert_no_selector "a[href*='start_date=']"
  end
end
