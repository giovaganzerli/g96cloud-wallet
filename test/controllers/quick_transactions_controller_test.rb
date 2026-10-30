require "test_helper"

class QuickTransactionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
    @account.round_up_setting&.destroy!
    @destination = @user.family.accounts.create!(
      name: "Savings",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
  end

  test "renders the quick page as a standalone screen" do
    get quick_new_transaction_url

    assert_response :success
    assert_select "turbo-frame#quick-new-form"
    assert_select "form[action='#{transactions_path}']"
    assert_select "nav[data-viewport-target='bottomNav']", count: 0
    assert_select "#main"
    assert_includes response.body, I18n.t("transactions.quick_new.heading")
    assert_includes response.body, I18n.t("transactions.form.round_up_label")
  end

  test "renders the transfer form inside the quick page" do
    get quick_new_transaction_url(nature: "transfer")

    assert_response :success
    assert_select "turbo-frame#quick-new-form"
    assert_select "form[action='#{transfers_path}']"
    assert_select "form[action='#{transactions_path}']", count: 0
  end

  test "the quick page does not leak the app sidebar or bottom navigation" do
    get quick_new_transaction_url

    assert_select "a[href='#{root_path}']", count: 0
    assert_select "[data-viewport-target='bottomNav']", count: 0
  end

  test "a blank description becomes Expense" do
    post transactions_url, params: { entry: transaction_params(amount: "12.50", nature: "outflow") }

    assert_redirected_to account_path(Entry.order(:created_at).last.account)
    assert_equal "Expense", Entry.order(:created_at).last.name
  end

  test "a blank description becomes Income for inflows" do
    post transactions_url, params: { entry: transaction_params(amount: "12.50", nature: "inflow") }

    assert_equal "Income", Entry.order(:created_at).last.name
  end

  test "an explicit description is preserved" do
    post transactions_url, params: { entry: transaction_params(amount: "12.50", name: "Coffee") }

    assert_equal "Coffee", Entry.order(:created_at).last.name
  end

  test "quick create resets the form and shows a toast without navigating" do
    post transactions_url,
         params: { quick_new: "1", entry: transaction_params(amount: "12.50") },
         as: :turbo_stream

    assert_response :success
    assert_includes response.body, 'target="quick-new-form"'
    assert_includes response.body, 'action="replace"'
    assert_includes response.body, I18n.t("transactions.create.created")
    assert_includes response.body, 'target="notification-tray"'
  end

  test "quick create falls back to a redirect without JavaScript" do
    post transactions_url, params: { quick_new: "1", entry: transaction_params(amount: "12.50") }

    assert_redirected_to quick_new_transaction_url(nature: "outflow")
  end

  test "quick create re-renders the frame when the entry is invalid" do
    post transactions_url,
         params: { quick_new: "1", entry: transaction_params(amount: "") },
         as: :turbo_stream

    assert_response :unprocessable_entity
    assert_select "turbo-frame#quick-new-form"
    assert_select "form[action='#{transactions_path}']"
  end

  test "quick transfer create resets the transfer form in place" do
    post transfers_url,
         params: {
           quick_new: "1",
           transfer: {
             from_account_id: @account.id,
             to_account_id: @destination.id,
             date: Date.current,
             amount: "10.00"
           }
         },
         as: :turbo_stream

    assert_response :success
    assert_includes response.body, 'target="quick-new-form"'
    assert_includes response.body, 'action="replace"'
    assert_includes response.body, I18n.t("transfers.form.submit")
  end

  test "moves spare change when the account has the feature and the toggle is on" do
    @account.create_round_up_setting!(enabled: true, destination_account: @destination, multiplier: 1)

    assert_difference -> { Transfer.count }, 1 do
      assert_difference -> { Entry.count }, 3 do
        post transactions_url,
             params: { quick_new: "1", entry: transaction_params(amount: "1.20", round_up_enabled: "1") },
             as: :turbo_stream
      end
    end

    transfer = Transfer.order(:created_at).last

    assert_equal BigDecimal("0.80"), transfer.amount
    assert_equal @account, transfer.from_account
    assert_equal @destination, transfer.to_account
    assert_equal "Spare change to Savings", transfer.outflow_transaction.entry.name
    assert_equal "Spare change from Checking Account", transfer.inflow_transaction.entry.name
    assert_nil transfer.outflow_transaction.entry.idempotency_key,
      "no idempotency key was submitted, so the round-up transfer is not keyed either"
  end

  test "spare change respects the multiplier" do
    @account.create_round_up_setting!(enabled: true, destination_account: @destination, multiplier: 5)

    post transactions_url,
         params: { quick_new: "1", entry: transaction_params(amount: "2.00", round_up_enabled: "1") },
         as: :turbo_stream

    assert_equal BigDecimal("5.00"), Transfer.order(:created_at).last.amount
  end

  test "a tampered toggle does nothing when the account has no setting" do
    assert_no_difference "Transfer.count" do
      assert_difference "Entry.count", 1 do
        post transactions_url,
             params: { quick_new: "1", entry: transaction_params(amount: "1.20", round_up_enabled: "1") },
             as: :turbo_stream
      end
    end
  end

  test "spare change is ignored for inflows" do
    @account.create_round_up_setting!(enabled: true, destination_account: @destination, multiplier: 1)

    assert_no_difference "Transfer.count" do
      post transactions_url,
           params: { quick_new: "1", entry: transaction_params(amount: "1.20", nature: "inflow", round_up_enabled: "1") },
           as: :turbo_stream
    end
  end

  private
    def transaction_params(amount:, nature: "outflow", name: "", round_up_enabled: "0")
      {
        account_id: @account.id,
        name: name,
        date: Date.current,
        currency: "USD",
        amount: amount,
        nature: nature,
        entryable_type: "Transaction",
        round_up_enabled: round_up_enabled,
        entryable_attributes: { category_id: categories(:food_and_drink).id }
      }
    end
end
