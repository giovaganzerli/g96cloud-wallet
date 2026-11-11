require "test_helper"

class Settings::PreferencesControllerPaydayTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    sign_in @user
  end

  test "the preferences page offers the family's tags as payday labels" do
    get settings_preferences_url

    assert_response :success
    # The payday label uses the design system's select, which renders a hidden
    # input plus a trigger button rather than a native select.
    assert_select "input[name='user[family_attributes][payday_tag_id]']"
    assert_select "button#payday_tag_id_trigger"
  end

  test "the page names the month the payday produces" do
    tag = @family.tags.create!(name: "Payday", color: Tag::COLORS.first)
    @family.update!(payday_tag: tag)
    entry = create_transaction(name: "Salary", date: Date.new(2026, 10, 28), amount: -2000)
    entry.entryable.update!(tag_ids: [ tag.id ])

    get settings_preferences_url

    assert_response :success
    prefix = I18n.t("settings.preferences.show.payday_active_message", range: "").sub(/:\s*\.\z/, "").strip
    assert_includes response.body, prefix
    # The month the payday opens, and the day before the next one.
    assert_includes response.body, I18n.l(Date.new(2026, 10, 28), format: :long)
  end

  test "the payday label is saved with the other family preferences" do
    tag = @family.tags.create!(name: "Payday", color: Tag::COLORS.first)

    patch user_url(@user), params: {
      user: {
        first_name: @user.first_name,
        family_attributes: { payday_tag_id: tag.id }
      }
    }

    assert_equal tag.id, @family.reload.payday_tag_id
  end

  test "a tag from another family is rejected" do
    other_tag = families(:empty).tags.create!(name: "Elsewhere", color: Tag::COLORS.first)

    patch user_url(@user), params: {
      user: {
        first_name: @user.first_name,
        family_attributes: { payday_tag_id: other_tag.id }
      }
    }

    assert_nil @family.reload.payday_tag_id
  end
end
