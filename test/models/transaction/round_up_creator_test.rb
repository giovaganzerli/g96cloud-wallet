require "test_helper"

class Transaction::RoundUpCreatorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @destination = @family.accounts.create!(
      name: "Savings",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    @user = users(:family_admin)
    @setting = @account.create_round_up_setting!(
      enabled: true,
      destination_account: @destination,
      multiplier: 1
    )
  end

  test "moves the cents needed to reach the next whole unit" do
    creator = build_creator(amount: "1.20")

    assert creator.enabled?
    assert_equal BigDecimal("0.80"), creator.calculated_amount
  end

  test "moves one whole unit when the amount is already round" do
    creator = build_creator(amount: "2.00")

    assert_equal BigDecimal("1.00"), creator.calculated_amount
  end

  test "applies the configured multiplier" do
    @setting.update!(multiplier: 10)
    creator = build_creator(amount: "2.00")

    assert_equal BigDecimal("10.00"), creator.calculated_amount
  end

  test "creates a transfer to the configured destination" do
    creator = build_creator(amount: "1.20", idempotency_key: "6ad9a7e0-8b1a-4b6d-9f3a-1a2b3c4d5e6f")

    assert_difference "Transfer.count", 1 do
      assert_difference "Entry.count", 2 do
        transfer = creator.create

        assert transfer.persisted?
        assert_equal BigDecimal("0.80"), transfer.amount
        assert_equal @account, transfer.from_account
        assert_equal @destination, transfer.to_account
        assert_equal "Spare change to Savings", transfer.outflow_transaction.entry.name
        assert_equal "Spare change from Checking Account", transfer.inflow_transaction.entry.name
        assert_equal "funds_movement", transfer.outflow_transaction.kind
        assert_equal "6ad9a7e0-8b1a-4b6d-9f3a-1a2b3c4d5e6f-roundup", transfer.outflow_transaction.entry.idempotency_key
      end
    end
  end

  test "does nothing when the toggle is off" do
    creator = build_creator(amount: "1.20", enabled: false)

    assert_not creator.enabled?
    assert_no_difference "Transfer.count" do
      assert_nil creator.create
    end
  end

  test "does nothing when the account has no setting" do
    @setting.destroy!

    creator = build_creator(amount: "1.20")

    assert_not creator.enabled?
    assert_no_difference "Transfer.count" do
      assert_nil creator.create
    end
  end

  test "does nothing when the setting is disabled" do
    @setting.update!(enabled: false)

    creator = build_creator(amount: "1.20")

    assert_not creator.enabled?
  end

  test "does nothing for an inflow" do
    creator = build_creator(amount: "-12.40")

    assert_not creator.enabled?
  end

  test "does nothing when the user cannot write to the destination" do
    creator = build_creator(amount: "1.20", user: users(:family_member))

    assert_not creator.enabled?
    assert_no_difference "Transfer.count" do
      assert_nil creator.create
    end
  end

  private
    def build_creator(amount:, enabled: true, idempotency_key: nil, user: @user)
      entry = @account.entries.build(
        name: "Coffee",
        amount: amount,
        currency: "USD",
        date: Date.current,
        entryable: Transaction.new
      )

      Transaction::RoundUpCreator.new(
        parent_entry: entry,
        account: @account,
        family: @family,
        enabled: enabled,
        idempotency_key: idempotency_key,
        user: user
      )
    end
end
