class Settings::TravelModesController < ApplicationController
  def show
    @tags = Current.family.tags.alphabetically
  end

  def update
    tag_id = Array(params.dig(:user, :travel_tag_ids)).reject(&:blank?).first
    tag = Current.family.tags.find_by(id: tag_id) if tag_id
    Current.user.update_travel_tag(tag)
    redirect_to settings_travel_mode_path, notice: t("settings.travel_modes.updated")
  end
end
