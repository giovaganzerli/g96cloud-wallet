class CryptoActivitiesController < ApplicationController
  before_action :set_account

  def new
    @activity = Crypto::ActivityForm.new(account: @account, occurred_at: Time.current.utc.strftime("%Y-%m-%dT%H:%M"))
  end

  def create
    @activity = Crypto::ActivityForm.new(activity_params.merge(account: @account))
    if @activity.save
      redirect_to account_path(@account), notice: t("crypto_ledger.saved"), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def quote
    zone = Time.find_zone!(params.fetch(:time_zone, "UTC"))
    raise ArgumentError unless zone
    at = zone.parse(params.require(:occurred_at))
    raise ArgumentError unless at && at <= Time.current
    quote = Crypto::HistoricalQuote.fetch(symbol: params.require(:symbol), at: at)
    render json: { price: quote.price.to_s("F"), currency: quote.currency, quoted_at: quote.quoted_at.iso8601, source: quote.source }
  rescue Crypto::HistoricalQuote::UnavailableError, ArgumentError, TypeError => e
    render json: { error: e.is_a?(Crypto::HistoricalQuote::UnavailableError) ? e.message : t("crypto_ledger.invalid_time") }, status: :unprocessable_entity
  end

  private

    def set_account
      @account = Current.family.accounts.accessible_by(Current.user).find(params[:account_id])
      return unless require_account_permission!(@account)
      head :unprocessable_entity unless @account.crypto? && @account.manual?
    end

    def activity_params
      params.require(:crypto_activity).permit(:description, :occurred_at, :time_zone, :kind, :symbol,
        :quantity, :unit_price_eur, :value_eur, :fee_eur, :counter_symbol, :counter_quantity, :balance_after, :funded_from_wallet, :suggested_price)
    end
end
