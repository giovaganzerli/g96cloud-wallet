class Account::CashbackSetting < ApplicationRecord
  belongs_to :account, inverse_of: :cashback_setting

  validates :percentage, numericality: { greater_than: 0, less_than_or_equal_to: 100 }, if: :enabled?
end
