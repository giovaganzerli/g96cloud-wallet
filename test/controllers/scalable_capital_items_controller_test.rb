require "test_helper"

class ScalableCapitalItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    @item = scalable_capital_items(:one)
  end

  test "admin can create a connection without submitting broker credentials" do
    with_self_hosting do
      assert_difference "ScalableCapitalItem.count", 1 do
        post scalable_capital_items_url, params: {
          scalable_capital_item: { name: "My investments", status: "good", family_id: families(:empty).id }
        }
      end
      item = families(:dylan_family).scalable_capital_items.ordered.first
      assert_redirected_to scalable_capital_item_path(item)
      assert item.requires_update?
      assert_equal families(:dylan_family), item.family
    end
  end

  test "instructions display the opaque connection identifier" do
    with_self_hosting do
      get scalable_capital_item_url(@item)
      assert_response :success
      assert_select "code", text: @item.login_command
    end
  end

  test "connections cannot be accessed across families" do
    with_self_hosting do
      get scalable_capital_item_url(scalable_capital_items(:other_family))
      assert_response :not_found
      post sync_scalable_capital_item_url(scalable_capital_items(:other_family))
      assert_response :not_found
    end
  end

  test "sync uses the normal background job pipeline" do
    with_self_hosting do
      SyncJob.expects(:perform_later).with { |sync| sync.syncable == @item }.once
      post sync_scalable_capital_item_url(@item)
      assert_redirected_to @item
    end
  end

  test "members cannot create or manage broker connections" do
    sign_in users(:family_member)
    with_self_hosting do
      assert_no_difference "ScalableCapitalItem.count" do
        post scalable_capital_items_url, params: { scalable_capital_item: { name: "Forbidden" } }, as: :json
      end
      assert_response :forbidden
      post sync_scalable_capital_item_url(@item), as: :json
      assert_response :forbidden
      delete scalable_capital_item_url(@item), as: :json
      assert_response :forbidden
    end
  end

  test "managed installations do not expose the CLI integration" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    get new_scalable_capital_item_url
    assert_response :not_found
  end

  test "bank sync settings show Scalable under investments and load its panel" do
    with_self_hosting do
      get settings_providers_url
      assert_response :success
      assert_select "turbo-frame#scalable_capital-providers-panel"
      get connect_form_settings_providers_url(provider_key: "scalable_capital")
      assert_response :success
      assert_select "a[href=?]", new_scalable_capital_item_path
    end
  end
end
