module QuickTransactionForm
  extend ActiveSupport::Concern

  included do
    helper_method :quick_transfer_idempotency_key
  end

  QUICK_NATURES = %w[outflow inflow transfer].freeze
  QUICK_FORM_FRAME = "quick-new-form".freeze

  private
    # The full-screen quick-entry page is rendered by two controllers (the
    # transaction form and the transfer form), so the request has to be
    # recognized from either one: `quick_new` for the GET, and the hidden
    # `quick_new` field echoed by both forms on submit.
    def quick_form_request?
      action_name == "quick_new" || params[:quick_new].present?
    end

    def quick_nature
      @quick_nature ||= begin
        requested = params[:nature].to_s
        QUICK_NATURES.include?(requested) ? requested : "outflow"
      end
    end

    def quick_transfer_idempotency_key
      @quick_transfer_idempotency_key ||= SecureRandom.uuid
    end

    # Shared by the modal form and the quick page. Renamed from
    # #set_new_transaction_form_options so TransfersController can reuse it
    # when rendering the quick page after a failed transfer.
    def set_transaction_form_options
      @account_currencies = accessible_accounts.pluck(:id, :currency).to_h
      @manual_accounts = accessible_accounts
        .manual
        .active
        .alphabetically
        .includes(:account_providers, :cashback_setting, logo_attachment: :blob)
        .to_a
      @categories = Current.family.categories.alphabetically_by_hierarchy.to_a
      @merchants = Current.family.available_merchants_for(Current.user).alphabetically.to_a
      @tags = Current.family.tags.alphabetically.to_a
      @round_up_accounts = round_up_accounts_for_form
    end

    # Builds the options the quick page needs regardless of which form is
    # displayed. Existing instance variables (a failed @entry/@transfer, the
    # submitted from_account_id) are preserved so a 422 re-render keeps the
    # user's input and validation errors.
    def set_quick_form_options(nature: quick_nature, entry: nil, transfer: nil)
      @quick_nature = nature
      @entry = entry || @entry || build_quick_entry
      @transfer = transfer || @transfer || Transfer.new
      @from_account_id ||= params[:from_account_id]
      @accounts ||= accessible_accounts
        .active
        .alphabetically
        .includes(:account_providers, logo_attachment: :blob)

      set_transaction_form_options
    end

    def quick_form_locals(nature: quick_nature, entry: nil, transfer: nil)
      {
        nature: nature,
        entry: entry || @entry,
        account_currencies: @account_currencies,
        manual_accounts: @manual_accounts,
        categories: @categories,
        merchants: @merchants,
        tags: @tags,
        round_up_accounts: @round_up_accounts,
        transfer: transfer || @transfer,
        accounts: @accounts,
        from_account_id: @from_account_id
      }
    end

    def quick_form_streams(nature: quick_nature, entry: nil, transfer: nil)
      turbo_stream.replace(
        QUICK_FORM_FRAME,
        partial: "transactions/quick_form",
        locals: quick_form_locals(nature:, entry:, transfer:)
      )
    end

    def render_quick_form_error(nature: quick_nature)
      set_quick_form_options(nature:)
      # A Turbo frame submission may negotiate turbo_stream, but validation
      # failures deliberately return the matching HTML frame so Turbo can
      # replace just the form and preserve its 422 semantics.
      render "transactions/quick_new",
             formats: :html,
             layout: "quick",
             status: :unprocessable_entity
    end

    def build_quick_entry
      account = accessible_accounts.find_by(id: params[:account_id])

      entry = Current.family.entries.new(
        account: account,
        currency: account&.currency || Current.family.currency,
        entryable: Transaction.new
      )
      entry.transaction.tag_ids = [ Current.user.travel_tag.id ] if Current.user.travel_tag
      entry
    end

    # Only accounts the user can actually move money into: the destination is
    # re-checked with write permission, exactly like the round-up creator does
    # server-side, so the form never offers a toggle the save would reject.
    def round_up_accounts_for_form
      accessible_accounts
        .where(accountable_type: "Depository")
        .joins(:round_up_setting)
        .where(account_round_up_settings: { enabled: true })
        .includes(round_up_setting: :destination_account)
        .each_with_object({}) do |account, accounts|
          setting = account.round_up_setting
          next unless account.round_ups_available_for?(Current.user)

          accounts[account.id.to_s] = {
            destination: setting.destination_account.name,
            multiplier: setting.multiplier,
            currency: account.currency
          }
        end
    end
end
