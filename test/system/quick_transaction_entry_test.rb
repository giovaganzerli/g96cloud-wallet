require "application_system_test_case"

class QuickTransactionEntryTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
    @savings = @user.family.accounts.create!(
      name: "Savings",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
  end

  test "enters an expense without leaving the quick page" do
    @account.create_round_up_setting!(enabled: true, destination_account: @savings, multiplier: 1)

    visit quick_new_transaction_path

    assert_selector "turbo-frame#quick-new-form"
    assert_no_selector "nav[data-viewport-target='bottomNav']"

    select_ds("Account", @account)
    fill_in "Amount", with: "1.20"

    # The spare-change row follows the selected account, and defaults to on.
    assert_selector "[data-transaction-form-target='roundUpSection']", visible: true
    assert find("[data-transaction-form-target='roundUpToggle']", visible: :all).checked?

    transfers_before = Transfer.count

    click_button I18n.t("transactions.form.submit")

    assert_text I18n.t("transactions.create.created")

    # In-place reset: same page, empty amount, ready for the next entry.
    assert_current_path quick_new_transaction_path
    assert_equal "", find("#entry_amount").value

    entry = @account.entries.find_by!(name: "Expense")
    assert_equal "Expense", entry.name

    assert_equal transfers_before + 1, Transfer.count
    transfer = Transfer.order(:created_at).last
    assert_equal BigDecimal("0.80"), transfer.amount
    assert_equal I18n.t("transactions.round_up.outflow_name", destination: @savings.name),
                 transfer.outflow_transaction.entry.name
  end

  test "switches to the transfer form inside the same frame" do
    visit quick_new_transaction_path

    click_link I18n.t("shared.transaction_tabs.transfer")

    assert_selector "turbo-frame#quick-new-form form[action='#{transfers_path}']"
    # This is a frame navigation, so the quick-entry page URL stays stable.
    assert_current_path quick_new_transaction_path
  end
end
