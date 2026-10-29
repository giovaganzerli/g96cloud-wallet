require "test_helper"

class Account::RoundUpSettingTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @destination = @family.accounts.create!(
      name: "Savings",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
  end

  test "is valid when enabled with an active depository destination" do
    setting = @account.create_round_up_setting!(
      enabled: true,
      destination_account: @destination,
      multiplier: 2
    )

    assert setting.persisted?
    assert_equal 2, setting.multiplier
    assert_equal "x2", setting.multiplier_label
  end

  test "defaults to a disabled x1 setting" do
    setting = @account.create_round_up_setting!

    assert_not setting.enabled?
    assert_equal 1, setting.multiplier
  end

  test "requires a destination once enabled" do
    setting = @account.build_round_up_setting(enabled: true)

    assert_not setting.valid?
    assert setting.errors[:destination_account_id].any?
  end

  test "rejects an unsupported multiplier" do
    setting = @account.build_round_up_setting(enabled: true, destination_account: @destination, multiplier: 7)

    assert_not setting.valid?
    assert setting.errors[:multiplier].any?
  end

  test "rejects itself as the destination" do
    setting = @account.build_round_up_setting(enabled: true, destination_account: @account)

    assert_not setting.valid?
    assert setting.errors[:account].any?
  end

  test "rejects a destination outside the family" do
    other_family_account = families(:empty).accounts.create!(
      name: "Someone Else",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    setting = @account.build_round_up_setting(enabled: true, destination_account: other_family_account)

    assert_not setting.valid?
    assert setting.errors[:destination_account].any?
  end

  test "rejects a non-depository destination" do
    setting = @account.build_round_up_setting(enabled: true, destination_account: accounts(:investment))

    assert_not setting.valid?
    assert setting.errors[:destination_account].any?
  end

  test "rejects an inactive destination" do
    @destination.update!(status: "disabled")

    setting = @account.build_round_up_setting(enabled: true, destination_account: @destination)

    assert_not setting.valid?
    assert setting.errors[:destination_account].any?
  end

  test "rejects a source account that is not a depository" do
    credit_card = accounts(:credit_card)

    setting = credit_card.build_round_up_setting(destination_account: @destination)

    assert_not setting.valid?
    assert setting.errors[:account].any?
  end
end
