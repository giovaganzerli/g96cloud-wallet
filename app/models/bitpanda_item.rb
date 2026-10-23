class BitpandaItem < ApplicationRecord
  include Syncable, DestroyableLater, Encryptable

  belongs_to :family
  has_many :bitpanda_accounts, dependent: :destroy
  has_many :accounts, through: :bitpanda_accounts

  encrypts :api_key if encryption_ready?

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  normalizes :api_key, with: ->(value) { value.strip }
  validates :name, :api_key, presence: true

  scope :ordered, -> { order(created_at: :desc) }
  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }

  def provider
    Provider::Bitpanda.new(api_key: api_key)
  end

  def institution_display_name
    name
  end

  def credentials_configured?
    api_key.present?
  end

  def review_required?
    accounts.joins(:trades).where(entries: { source: "bitpanda", excluded: false })
      .where("trades.extra -> 'bitpanda' ->> 'review_required' = 'true'").exists? ||
      accounts.joins(:transactions).where(entries: { source: "bitpanda", excluded: false })
        .where("transactions.extra -> 'bitpanda' ->> 'review_required' = 'true'").exists?
  end
end
