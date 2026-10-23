class UI::Account::ActivityDate < ApplicationComponent
  attr_reader :account, :data, :crypto_rows

  delegate :date, :entries, :balance, :transfers, :split_parents, to: :data

  def initialize(account:, data:, crypto_rows: {})
    @account = account
    @data = data
    @crypto_rows = crypto_rows
  end

  def id
    dom_id(account, "entries_#{date}")
  end

  def broadcast_channel
    account
  end

  def end_balance_money
    balance&.end_balance_money || Money.new(0, account.currency)
  end

  def broadcast_refresh!
    Turbo::StreamsChannel.broadcast_replace_to(
      broadcast_channel,
      target: id,
      renderable: self,
      layout: false
    )
  end
end
