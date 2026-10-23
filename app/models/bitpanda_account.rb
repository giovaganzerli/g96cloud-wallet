class BitpandaAccount < ApplicationRecord
  include Encryptable

  belongs_to :bitpanda_item
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider

  serialize :raw_payload, coder: JSON
  encrypts :raw_payload if encryption_ready?

  validates :account_id, :name, :currency, presence: true
  validates :account_id, uniqueness: { scope: :bitpanda_item_id }

  def current_account
    account
  end
end
