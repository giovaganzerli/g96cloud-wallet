require "test_helper"

class PeriodRangesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "renders the modal with the target path and the extra params" do
    get period_range_path(url: "/accounts/abc", chart_view: "gains")

    assert_response :success
    assert_select "form[action='/accounts/abc']"
    assert_select "input[name='chart_view'][value='gains']"
    assert_select "input[name='start_date']"
    assert_select "input[name='end_date']"
  end

  test "a target outside the app falls back to the dashboard" do
    get period_range_path(url: "https://example.com/phishing")

    assert_response :success
    assert_select "form[action='#{root_path}']"
  end

  test "a protocol-relative target falls back to the dashboard" do
    get period_range_path(url: "//example.com/phishing")

    assert_response :success
    assert_select "form[action='#{root_path}']"
  end

  test "the range currently applied comes back as the field values" do
    get period_range_path(url: "/accounts/abc", start_date: "2026-09-01", end_date: "2026-09-30")

    assert_response :success
    assert_select "input[name='start_date'][value='2026-09-01']"
    assert_select "input[name='end_date'][value='2026-09-30']"
  end
end
