class BitpandaItemsController < ApplicationController
  before_action :require_admin!
  before_action :set_item, only: %i[show update sync destroy]

  def new
    @bitpanda_item = Current.family.bitpanda_items.build(name: "Bitpanda")
  end

  def create
    @bitpanda_item = Current.family.bitpanda_items.build(item_params)
    if @bitpanda_item.save
      @bitpanda_item.sync_later
      redirect_to @bitpanda_item, notice: t("bitpanda_items.sync_queued"), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
  end

  def update
    if @bitpanda_item.update(item_params)
      @bitpanda_item.sync_later unless @bitpanda_item.scheduled_for_deletion?
      redirect_to @bitpanda_item, notice: t("bitpanda_items.sync_queued"), status: :see_other
    else
      render :show, status: :unprocessable_entity
    end
  end

  def sync
    @bitpanda_item.sync_later unless @bitpanda_item.scheduled_for_deletion?
    redirect_to @bitpanda_item, notice: t("bitpanda_items.sync_queued"), status: :see_other
  end

  def destroy
    # AccountProvider nullifies holding ownership on deletion; the user's
    # canonical accounts, entries and holdings remain as manual records.
    @bitpanda_item.destroy_later
    redirect_to accounts_path, notice: t("bitpanda_items.disconnected"), status: :see_other
  end

  private

    def set_item
      @bitpanda_item = Current.family.bitpanda_items.find(params[:id])
    end

    def item_params
      permitted = params.require(:bitpanda_item).permit(:name, :api_key)
      permitted.delete(:api_key) if @bitpanda_item&.persisted? && permitted[:api_key].blank?
      permitted
    end
end
