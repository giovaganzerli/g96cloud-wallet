class ScalableCapitalAccount < ApplicationRecord
  belongs_to :scalable_capital_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider

  validates :portfolio_id, :provider_account_id, :name, :currency, presence: true
  validates :portfolio_id, uniqueness: { scope: :scalable_capital_item_id }

  def current_account
    account
  end
end
