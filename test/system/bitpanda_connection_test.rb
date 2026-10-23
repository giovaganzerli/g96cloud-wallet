require "application_system_test_case"

class BitpandaConnectionTest < ApplicationSystemTestCase
  test "admin connects Bitpanda from Crypto without exposing the stored API key" do
    BitpandaItem.any_instance.stubs(:sync_later)
    Provider::Bitpanda.any_instance.expects(:snapshot).never
    sign_in users(:family_admin)
    visit accounts_url
    click_link I18n.t("accounts.index.new_account")
    click_link Accountable.from_type("Crypto").singular_display_name
    click_link I18n.t("accounts.new.method_selector.link_with_provider", provider: "Bitpanda")
    fill_in "bitpanda_item_name", with: "My crypto portfolio"
    fill_in "bitpanda_item_api_key", with: "synthetic-bitpanda-key"
    click_button I18n.t("bitpanda_items.save_connection")

    assert_text "My crypto portfolio"
    item = families(:dylan_family).bitpanda_items.find_by!(name: "My crypto portfolio")
    assert_current_path bitpanda_item_path(item)
    assert_selector "input[name='bitpanda_item[api_key]'][type=password]"
    assert_equal "", find("input[name='bitpanda_item[api_key]']").value
    assert_no_text "synthetic-bitpanda-key"
  end
end
