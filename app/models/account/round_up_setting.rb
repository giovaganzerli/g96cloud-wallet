class Account::RoundUpSetting < ApplicationRecord
  # "Spare change": every manually created expense on a depository account can
  # round up to the next whole currency unit and move the difference to a
  # savings-like account. The multiplier repeats that difference, so x2 moves
  # twice the rounded-up cents.
  MULTIPLIERS = [ 1, 2, 3, 4, 5, 10 ].freeze

  belongs_to :account
  belongs_to :destination_account, class_name: "Account", optional: true

  validates :multiplier, inclusion: { in: MULTIPLIERS }
  validates :destination_account_id, presence: true, if: :enabled?

  validate :account_must_be_depository
  validate :destination_must_be_usable, if: -> { enabled? && destination_account_id? }

  def multiplier_label
    "x#{multiplier}"
  end

  private
    def account_must_be_depository
      return if account.nil? || account.depository?

      errors.add(:account, :invalid)
    end

    def destination_must_be_usable
      if destination_account.nil?
        errors.add(:destination_account, :invalid)
        return
      end

      # Same-family is the tenancy boundary; never let a config move money
      # into another family's account even if a tampered form submits the id.
      return errors.add(:destination_account, :invalid) unless destination_account.family_id == account&.family_id

      errors.add(:account, :invalid) if destination_account_id == account_id
      errors.add(:destination_account, :invalid) unless destination_account.depository?
      errors.add(:destination_account, :invalid) unless destination_account.active?
    end
end
