require "application_system_test_case"

class TransactionsFormExchangeRateTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account_usd = accounts(:depository) # USD account
    sign_in @user

    # Set up real exchange rates for testing
    @eur_usd_rate = ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: Date.current,
      rate: 1.1
    )

    @gbp_usd_rate = ExchangeRate.create!(
      from_currency: "GBP",
      to_currency: "USD",
      date: Date.current,
      rate: 1.27
    )
  end

  test "changing amount currency to different currency shows exchange rate UI" do
    visit new_transaction_path

    assert_selector "form[data-controller~='transaction-form'] [data-transaction-form-target='exchangeRateContainer']", visible: :all

    # Select USD account (which is in USD)
    select_ds("Account", @account_usd)

    # Currency defaults to USD (same as account)
    # Change currency to EUR
    change_currency_to("EUR")

    # Exchange rate UI should appear
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true
  end

  test "closing the tag search preserves the enclosing transaction dialog" do
    visit new_transaction_path
    click_button I18n.t("transactions.form.search_tags")
    within "[data-tag-chip-tools-target='searchDialog'][open]" do
      click_button I18n.t("ds.dialog.close")
    end
    assert_no_selector "[data-tag-chip-tools-target='searchDialog'][open]"
    assert_selector "form[data-controller~='transaction-form']"
    select_ds("Account", @account_usd)
    change_currency_to("EUR")
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true
  end

  test "changing amount currency to same as account currency hides exchange rate UI" do
    visit new_transaction_path

    # Select USD account
    select_ds("Account", @account_usd)

    # Change to EUR first
    change_currency_to("EUR")

    # Verify exchange rate UI is shown
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true

    # Change back to USD (same as account)
    change_currency_to("USD")

    # Exchange rate UI should hide
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: false
  end

  test "exchange rate field is prefilled when rate is available" do
    visit new_transaction_path

    # Select USD account
    select_ds("Account", @account_usd)

    # Change to GBP (exchange rate is set up in fixtures)
    change_currency_to("GBP")

    # Wait for exchange rate container to become visible
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true

    # Exchange rate is fetched asynchronously — wait for the field value.
    assert_equal "1.27", wait_for_exchange_rate_value("1.27")
  end

  test "exchange rate field is empty when rate not found" do
    visit new_transaction_path

    # Select USD account
    select_ds("Account", @account_usd)

    # Change to CHF (Swiss Franc - no rate set up in fixtures)
    change_currency_to("CHF")

    # Wait for exchange rate container to become visible (manual rate entry mode)
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true

    # Exchange rate section should be visible but field should be empty (manual entry)
    exchange_rate_field = find("[data-transaction-form-target='exchangeRateField']")
    assert_empty exchange_rate_field.value
  end

  test "exchange rate is recalculated when currency changes" do
    visit new_transaction_path

    # Select USD account
    select_ds("Account", @account_usd)

    # Change to EUR
    change_currency_to("EUR")

    # Wait for EUR rate to load (async fetch)
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true
    first_rate = wait_for_exchange_rate_value("1.10")

    # Change to GBP
    change_currency_to("GBP")

    # Wait for the field to flip from EUR→GBP; reading immediately is flaky
    # because the previous value stays until the fetch completes.
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true
    second_rate = wait_for_exchange_rate_value("1.27")

    # Rates should be different
    assert_not_equal first_rate, second_rate
  end

  test "changing account also recalculates exchange rate for current currency" do
    # Create a second account in EUR
    eur_account = @family.accounts.create!(
      name: "EUR Account",
      balance: 1000,
      currency: "EUR",
      accountable: Depository.new
    )

    visit new_transaction_path

    # Start with USD account, then currency EUR
    select_ds("Account", @account_usd)

    change_currency_to("EUR")

    # Exchange rate shown (both USD and EUR exist, they differ)
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: true
    wait_for_exchange_rate_value("1.10")

    # Switch to EUR account
    select_ds("Account", eur_account)

    # Now account is EUR and currency is EUR (same)
    # Exchange rate UI should hide
    assert_selector "[data-transaction-form-target='exchangeRateContainer']", visible: false
  end

  private
    def change_currency_to(currency)
      select = find("select[data-money-field-target='currency']")
      select.find("option[value='#{currency}']").select_option
    end

    # JS sets the input's value property after an async fetch. Waiting on the
    # HTML value= attribute is unreliable, so filter the node by .value.
    def wait_for_exchange_rate_value(expected)
      find("[data-transaction-form-target='exchangeRateField']") { |node| node.value == expected }.value
    end
end
