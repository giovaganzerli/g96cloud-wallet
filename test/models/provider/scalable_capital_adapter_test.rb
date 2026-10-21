require "uri"

require "test_helper"

class Provider::ScalableCapitalAdapterTest < ActiveSupport::TestCase
  include ProviderAdapterTestInterface

  setup do
    @item = scalable_capital_items(:one)
    @provider_account = @item.scalable_capital_accounts.create!(
      portfolio_id: "portfolio-1",
      provider_account_id: "account-1",
      name: "Scalable Capital",
      currency: "EUR",
      raw_payload: { "overview" => { "portfolio_id" => "portfolio-1" } }
    )
    @adapter = Provider::ScalableCapitalAdapter.new(@provider_account)
  end

  def adapter
    @adapter
  end

  test_provider_adapter_interface
  test_syncable_interface
  test_institution_metadata_interface

  test "connection config is offered for investment accounts on self-hosted installations" do
    with_self_hosting do
      config = Provider::ScalableCapitalAdapter.connection_configs(family: families(:empty)).first

      assert_equal "scalable_capital", config[:key]
      assert_equal "Scalable Capital", config[:name]
      assert config[:can_connect]
      assert_equal "/scalable_capital_items/new", URI.parse(config[:new_account_path].call("Investment", "/accounts")).path
    end
  end

  test "connection config is hidden on managed installations" do
    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)

    assert_empty Provider::ScalableCapitalAdapter.connection_configs(family: families(:empty))
  end

  test "adapter only supports investment accounts" do
    assert_equal %w[Investment], Provider::ScalableCapitalAdapter.supported_account_types
  end
end
