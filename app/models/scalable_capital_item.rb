class ScalableCapitalItem < ApplicationRecord
  include Syncable, DestroyableLater

  belongs_to :family
  has_many :scalable_capital_accounts, dependent: :destroy
  has_many :accounts, through: :scalable_capital_accounts

  enum :status, { good: "good", requires_update: "requires_update" }, default: :requires_update

  validates :name, presence: true

  scope :ordered, -> { order(created_at: :desc) }
  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active.good }

  def provider
    Provider::ScalableCapital.new(self)
  end

  def institution_display_name
    name
  end

  # The CLI session lives in the container's storage rather than in the
  # database, so there is nothing to inspect here: the connection counts as
  # usable only once a synchronization has actually read the broker
  # successfully. A connection that has never synced, or whose session
  # expired, reports `requires_update` and asks for server authorization.
  def credentials_configured?
    good?
  end

  # Only opaque, server-generated UUIDs enter this operator command.
  def login_command
    "docker compose exec --user 1000:1000 worker ruby bin/scalable-capital-session #{id} login"
  end
end
