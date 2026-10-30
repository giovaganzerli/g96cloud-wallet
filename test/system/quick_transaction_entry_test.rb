require "application_system_test_case"

class QuickTransactionEntryTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
    @account.round_up_setting&.destroy!
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

    find("[data-quick-entry-target='toggle']").click
    find("#quick-entry-details label", text: tags(:one).name, exact_text: true).click
    find("#quick-entry-details label", text: tags(:two).name, exact_text: true).click

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
    assert_equal [ tags(:one).id, tags(:two).id ].sort, entry.entryable.tag_ids.sort

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

  test "creates a transfer through the calculator and its details panel" do
    visit quick_new_transaction_path(nature: "transfer")
    select_ds I18n.t("transactions.form.account"), @account
    select_ds I18n.t("transfers.form.to"), @savings
    fill_in "Amount", with: "15.25"
    find("[data-quick-entry-target='toggle']").click
    find("#quick-entry-details label", text: tags(:one).name, exact_text: true).click
    assert_selector "#quick-entry-details input[type='checkbox'][value='#{tags(:one).id}']:checked", visible: :all
    click_button I18n.t("transfers.form.submit")

    assert_text "Transfer created"
    assert_equal BigDecimal("15.25"), Transfer.order(:created_at).last.amount
    assert_equal [ tags(:one).id ], Transfer.order(:created_at).last.outflow_transaction.tag_ids
    assert_equal 0, find("#transfer_amount").value.to_d
  end

  test "calculator keys and sliding details preserve values and selected tags" do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit quick_new_transaction_path

    assert_no_selector "a[href='#{root_path}']"
    find("[data-key='1']").click
    find("[data-key='decimal']").click
    find("[data-key='2']").click
    find("[data-key='add']").click
    find("[data-key='3']").click
    find("[data-key='equals']").click
    assert_equal "4.2", find("#entry_amount").value
    page.save_screenshot(Rails.root.join("tmp/screenshots/quick_calculator_mobile.png"))

    toggle_quick_details
    assert_selector "[data-quick-entry-target='track'].-translate-x-full"
    fill_in I18n.t("transactions.form.description"), with: "Lunch"
    assert_selector "#quick-entry-details fieldset input[type='checkbox']", visible: :all
    assert_no_selector "#quick-entry-details [data-controller='tag-select']"
    page.save_screenshot(Rails.root.join("tmp/screenshots/quick_details_mobile.png"))

    toggle_quick_details
    assert_equal "4.2", find("#entry_amount").value
    toggle_quick_details
    assert_field I18n.t("transactions.form.description"), with: "Lunch"
  ensure
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end

  test "long amounts and tag names fit and detail labels share the same left edge" do
    @account.create_cashback_setting!(enabled: true, percentage: 2)
    tags(:one).update!(name: "International travel and accommodation", color: Tag::COLORS.first)
    page.driver.browser.manage.window.resize_to(390, 844)
    visit quick_new_transaction_path

    select_ds("Account", @account)
    fill_in "Amount", with: "123456789012345.67"
    assert_selector "#entry_amount[style]"
    assert_operator page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('#entry_amount')).fontSize)"), :<, 72
    select_styles = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('[data-quick-entry-target="primary"] button[aria-haspopup]'))
        .every(button => getComputedStyle(button).backgroundColor === 'rgba(0, 0, 0, 0)' && getComputedStyle(button).textAlign === 'center')
    JS
    assert select_styles

    find("[data-quick-entry-target='toggle']").click
    assert_field I18n.t("transactions.form.description")
    page.evaluate_async_script("const done = arguments[0]; Promise.all(document.querySelector('[data-quick-entry-target=track]').getAnimations().map(animation => animation.finished)).then(() => done(true));")
    find("label[for='entry_cashback_enabled']", text: I18n.t("transactions.form.cashback_label"), exact_text: true).click
    assert_unchecked_field "entry_cashback_enabled", visible: :all
    assert_no_selector "[data-transaction-form-target='cashbackDetails']", visible: :all
    label_edges = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('#quick-entry-details .form-field__label, #quick-entry-details legend, #quick-entry-details label[for="entry_cashback_enabled"]'))
        .filter(label => label.textContent.trim() && label.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true }) && label.getClientRects().length > 0)
        .map(label => [label.textContent, label.getBoundingClientRect().left])
    JS
    left_edges = label_edges.map(&:last)
    assert_operator left_edges.max - left_edges.min, :<=, 1, label_edges.inspect
    chips_fit = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('#quick-entry-details fieldset [data-controller="fit-text"]'))
        .every(chip => getComputedStyle(chip).whiteSpace === 'nowrap' && chip.scrollWidth <= chip.clientWidth)
    JS
    assert chips_fit
    color = find("#quick-entry-details label", text: tags(:one).name, exact_text: true)["style"]
    assert_includes color, tags(:one).color
  ensure
    page.driver.browser.manage.window.resize_to(1400, 1400)
  end

  test "quick selectors open searchable modal sheets and close after selection" do
    visit quick_new_transaction_path
    find("#account_id_trigger").click
    assert_selector "dialog[open] [data-select-sheet-body] input[type='search']"
    page.save_screenshot(Rails.root.join("tmp/screenshots/quick_select_sheet.png"))
    within "dialog[open]" do
      find("input[type='search']").set(@account.name)
      find("[role='option'][data-value='#{@account.id}']").click
    end
    assert_no_selector "dialog[open]"
    assert_equal @account.id, find("#entry_account_id", visible: :all).value

    find("[data-category-select-target='button']").click
    assert_selector "dialog[open] [data-category-select-target='search']"
    page.send_keys(:escape)
    assert_no_selector "dialog[open]"
    assert_selector "[data-quick-entry-target='primary']:not([inert])"
    page.execute_script("window.scrollTo(100, 100)")
    assert_equal [ 0, 0 ], page.evaluate_script("[window.scrollX, window.scrollY]")
  end

  test "shows the offline transaction queue section" do
    visit quick_new_transaction_path

    assert_selector "link[rel='manifest'][href='#{quick_pwa_manifest_path}']", visible: :all
    assert_text I18n.t("transactions.quick_new.offline_queue.title")
    assert_text I18n.t("transactions.quick_new.offline_queue.empty")
  end

  test "cashback follows account settings and preserves an explicit opt out" do
    @account.create_cashback_setting!(enabled: true, percentage: 2)
    visit quick_new_transaction_path
    select_ds("Account", @savings)
    fill_in "Amount", with: "100"
    toggle_quick_details
    assert_no_selector "[data-transaction-form-target='cashbackSection']"

    toggle_quick_details
    select_ds("Account", @account)
    toggle_quick_details
    assert_checked_field "entry_cashback_enabled", visible: :all
    find("label[for='entry_cashback_enabled']", text: I18n.t("transactions.form.cashback_label"), exact_text: true).click
    assert_unchecked_field "entry_cashback_enabled", visible: :all

    toggle_quick_details
    fill_in "Amount", with: "200"
    toggle_quick_details
    assert_unchecked_field "entry_cashback_enabled", visible: :all
    find("label[for='entry_cashback_enabled']", text: I18n.t("transactions.form.cashback_label"), exact_text: true).click
    click_button I18n.t("transactions.form.submit")
    assert_text I18n.t("transactions.create.created")
    cashback = @account.entries.where("name LIKE ?", "Cashback%").order(:created_at).last
    assert_equal BigDecimal("-4"), cashback.amount
  end

  test "tag dialogs do not submit or break the transaction form" do
    visit quick_new_transaction_path
    find("[data-quick-entry-target='toggle']").click
    page.evaluate_async_script("const done = arguments[0]; Promise.all(document.querySelector('[data-quick-entry-target=track]').getAnimations().map(animation => animation.finished)).then(() => done(true));")
    click_button I18n.t("transactions.form.search_tags")
    within "dialog[open]" do
      fill_in I18n.t("transactions.form.search_tags"), with: tags(:one).name
      click_button tags(:one).name, exact: true
      find("input[type='search']").send_keys(:enter)
    end
    within("dialog[open]") { click_button I18n.t("ds.dialog.close") }
    assert_no_selector "dialog[open]"
    assert_selector "#quick-entry-details input[value='#{tags(:one).id}']:checked", visible: :all

    click_button I18n.t("transactions.form.create_tag")
    within "dialog[open]" do
      find("[data-tag-chip-tools-target='createName']").set("Quick entry tag")
      click_button I18n.t("transactions.form.save")
    end
    assert_no_selector "dialog[open]"
    find("[data-quick-entry-target='toggle']").click
    assert_selector "#quick-entry-details label", text: "Quick entry tag"
    assert_selector "form[data-controller~='transaction-form'] [type='submit']"
  end

  private
    def toggle_quick_details
      if page.has_selector?("[data-quick-entry-target='primary'][inert]")
        find("#quick-entry-details button[data-action='quick-entry#toggle']").click
      else
        find("[data-quick-entry-target='toggle']").click
      end
      page.evaluate_async_script("const done = arguments[0]; Promise.all(document.querySelector('[data-quick-entry-target=track]').getAnimations().map(animation => animation.finished)).then(() => done(true));")
    end
end
