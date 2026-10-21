class ScalableCapitalItemsController < ApplicationController
  before_action :require_admin!
  before_action :require_self_hosting
  before_action :set_item, only: %i[show sync destroy]

  def new
    @scalable_capital_item = Current.family.scalable_capital_items.build(name: "Scalable Capital")
  end

  def create
    @scalable_capital_item = Current.family.scalable_capital_items.build(item_params)
    if @scalable_capital_item.save
      redirect_to @scalable_capital_item, status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
  end

  def sync
    @scalable_capital_item.sync_later unless @scalable_capital_item.scheduled_for_deletion?
    redirect_to @scalable_capital_item, notice: t("scalable_capital_items.sync_queued"), status: :see_other
  end

  def destroy
    @scalable_capital_item.destroy_later
    redirect_to accounts_path, notice: t("scalable_capital_items.disconnected"), status: :see_other
  end

  private

    def set_item
      @scalable_capital_item = Current.family.scalable_capital_items.find(params[:id])
    end

    def item_params
      params.require(:scalable_capital_item).permit(:name)
    end

    def require_self_hosting
      head :not_found unless Rails.application.config.app_mode.self_hosted?
    end
end
