require "application_system_test_case"

class MobileNavigationTest < ApplicationSystemTestCase
  PHONE = [ 375, 812 ].freeze

  setup do
    sign_in @user = users(:family_admin)
    page.driver.browser.manage.window.resize_to(*PHONE)
  end

  teardown do
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end

  test "the mobile bar exposes Dashboard, Transazioni, Stats and Budget" do
    visit root_path

    within "nav[data-viewport-target='bottomNav']" do
      assert_link I18n.t("layouts.application.nav.dashboard")
      assert_link I18n.t("layouts.application.nav.transactions")
      assert_link I18n.t("layouts.application.nav.stats"), href: reports_path
      assert_link I18n.t("layouts.application.nav.budgets"), href: budgets_path
    end
  end

  test "the center action opens the existing modal instead of the quick page" do
    visit root_path

    find("nav[data-viewport-target='bottomNav'] a[href='#{new_transaction_path}']").click

    assert_selector "turbo-frame#modal form[action='#{transactions_path}']"
    assert_text I18n.t("transactions.new.new_transaction")
    refute_includes page.current_path, quick_new_transaction_path
  end

  test "the assistant floats above the bar and steps aside on its own page" do
    visit root_path

    assert_selector "a[aria-label='#{I18n.t("layouts.application.nav.assistant")}']", visible: true

    visit chats_path

    assert_no_selector "a[aria-label='#{I18n.t("layouts.application.nav.assistant")}']"
  end
end
