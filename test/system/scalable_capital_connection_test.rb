require "application_system_test_case"

class ScalableCapitalConnectionTest < ApplicationSystemTestCase
  test "admin can reach Scalable from Investments and create an unauthenticated connection" do
    with_self_hosting do
      Provider::ScalableCapital.any_instance.expects(:login!).never
      Provider::ScalableCapital.any_instance.expects(:snapshot).never
      sign_in users(:family_admin)
      visit accounts_url
      click_link I18n.t("accounts.index.new_account")
      click_link Accountable.from_type("Investment").singular_display_name
      click_link I18n.t("accounts.new.method_selector.link_with_provider", provider: "Scalable Capital")
      fill_in "scalable_capital_item_name", with: "My Scalable investments"
      click_button I18n.t("scalable_capital_items.create_connection")

      # The redirect renders the connection page; waiting for its content keeps
      # the assertion from running while the request is still in flight.
      assert_text "My Scalable investments"
      item = families(:dylan_family).scalable_capital_items.find_by!(name: "My Scalable investments")
      assert_current_path scalable_capital_item_path(item)
      assert_selector "code", text: item.login_command
      assert_text I18n.t("scalable_capital_items.requires_update")
      assert item.requires_update?
      assert_empty item.accounts
    end
  end
end
