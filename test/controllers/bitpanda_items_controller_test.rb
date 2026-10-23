require "test_helper"

class BitpandaItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
    @item = bitpanda_items(:one)
  end

  test "admin creates a family scoped connection and queues the first sync" do
    SyncJob.expects(:perform_later).once
    assert_difference "BitpandaItem.count", 1 do
      post bitpanda_items_url, params: { bitpanda_item: {
        name: "Bitpanda", api_key: " new-key ", family_id: families(:empty).id, status: "requires_update"
      } }
    end
    item = families(:dylan_family).bitpanda_items.ordered.first
    assert_redirected_to item
    assert_equal "new-key", item.api_key
    assert item.good?
  end

  test "blank updates retain the existing key and management pages never render the key" do
    BitpandaItem.any_instance.stubs(:sync_later)
    patch bitpanda_item_url(@item), params: { bitpanda_item: { name: "Renamed", api_key: "" } }
    assert_equal "bitpanda-test-key", @item.reload.api_key
    get bitpanda_item_url(@item)
    assert_response :success
    assert_select "input[type=password][name='bitpanda_item[api_key]']"
    assert_not_includes response.body, "bitpanda-test-key"
  end

  test "connections cannot be read changed synchronized or deleted across families" do
    other = bitpanda_items(:other_family)
    get bitpanda_item_url(other)
    assert_response :not_found
    patch bitpanda_item_url(other), params: { bitpanda_item: { name: "Forbidden" } }
    assert_response :not_found
    post sync_bitpanda_item_url(other)
    assert_response :not_found
    delete bitpanda_item_url(other)
    assert_response :not_found
  end

  test "members cannot manage provider credentials" do
    sign_in users(:family_member)
    assert_no_difference "BitpandaItem.count" do
      post bitpanda_items_url, params: { bitpanda_item: { name: "Forbidden", api_key: "key" } }, as: :json
    end
    assert_response :forbidden
    get bitpanda_item_url(@item), as: :json
    assert_response :forbidden
    patch bitpanda_item_url(@item), params: { bitpanda_item: { api_key: "changed" } }, as: :json
    assert_response :forbidden
    post sync_bitpanda_item_url(@item), as: :json
    assert_response :forbidden
    delete bitpanda_item_url(@item), as: :json
    assert_response :forbidden
  end

  test "bank sync settings load the Crypto provider panel" do
    get settings_providers_url
    assert_response :success
    assert_select "turbo-frame#bitpanda-providers-panel"
    get connect_form_settings_providers_url(provider_key: "bitpanda")
    assert_response :success
    assert_select "a[href=?]", new_bitpanda_item_path
    assert_equal %w[Crypto], Provider::Metadata.for(:bitpanda)[:kinds]
    assert_equal %w[Crypto], Provider::BitpandaAdapter.supported_account_types
  end

  test "manual sync queues the standard job" do
    SyncJob.expects(:perform_later).with { |sync| sync.syncable == @item }.once
    post sync_bitpanda_item_url(@item)
    assert_redirected_to @item
  end
end
