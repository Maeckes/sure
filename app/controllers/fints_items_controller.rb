# frozen_string_literal: true

class FintsItemsController < ApplicationController
  before_action :require_admin!
  before_action :require_self_hosted_fints!
  before_action :set_fints_item, except: %i[new create]

  def new
    @fints_item = Current.family.fints_items.build(name: "ING FinTS", **Fints::Profile::ING)
    @fints_item.profile_id = @profile_id = "ing"
  end

  def create
    @profile_id = params.dig(:fints_item, :profile_id).to_s
    profile = Fints::Profile.resolve(id: @profile_id, **profile_params.to_h.symbolize_keys)
    @fints_item = Current.family.fints_items.build(fints_item_params.merge(profile))
    @fints_item.profile_id = @profile_id

    if @fints_item.save
      respond_to do |format|
        format.html { redirect_to accounts_fints_item_path(@fints_item), status: :see_other }
        format.json { render json: { id: @fints_item.id, status: @fints_item.status }, status: :created }
      end
    else
      render_create_error
    end
  rescue Fints::Profile::InvalidProfile => error
    @fints_item = Current.family.fints_items.build(fints_item_params.except(:pin))
    @fints_item.profile_id = @profile_id
    @fints_item.errors.add(:base, error.message)
    render_create_error
  end

  def discover
    result = @fints_item.discover_accounts!
    case result
    when Fints::WorkerClient::Success
      respond_to do |format|
        format.html { redirect_to accounts_fints_item_path(@fints_item) }
        format.json { render json: { accounts: serialized_accounts } }
      end
    when Fints::WorkerClient::Challenge
      render_challenge(result, operation: :discover)
    when Fints::WorkerClient::Failure
      render json: { error: result.message, code: result.code }, status: :unprocessable_entity
    end
  rescue Fints::WorkerClient::Error
    render json: { error: "The FinTS worker could not complete discovery." }, status: :bad_gateway
  end

  def accounts
    respond_to do |format|
      format.html do
        @fints_accounts = @fints_item.fints_accounts.order(:created_at)
        @linkable_accounts = Current.family.accounts.where.not(id: AccountProvider.select(:account_id)).order(:name)
      end
      format.json { render json: { accounts: serialized_accounts } }
    end
  end

  def map_account
    remote = @fints_item.fints_accounts.find(params.require(:fints_account_id))
    linked = if params[:account_id].present?
      account = Current.family.accounts.find(params[:account_id])
      remote.link_to_existing!(account)
      account
    else
      remote.create_and_link_account!(name: params[:name].presence || remote.name, subtype: params[:subtype].presence || remote.suggested_subtype)
    end
    respond_to do |format|
      format.html { redirect_to accounts_fints_item_path(@fints_item), notice: "FinTS account mapped." }
      format.json { render json: { account_id: linked.id, fints_account_id: remote.id }, status: :created }
    end
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    respond_to do |format|
      format.html { redirect_to accounts_fints_item_path(@fints_item), alert: error.message }
      format.json { render json: { error: error.message }, status: :unprocessable_entity }
    end
  end

  def sync
    result = @fints_item.import_latest_fints_data
    case result
    when Fints::WorkerClient::Challenge
      render_challenge(result, operation: :sync)
    when Fints::WorkerClient::Failure
      render json: { error: result.message, code: result.code }, status: :unprocessable_entity
    else
      if result.is_a?(Hash) && !result[:success]
        render json: { error: "The FinTS synchronization could not be completed." }, status: :unprocessable_entity
      else
        respond_to do |format|
          format.html { redirect_to accounts_path, notice: "FinTS synchronization completed." }
          format.json { render json: { status: "completed" } }
        end
      end
    end
  rescue Fints::WorkerClient::Error
    render json: { error: "The FinTS worker could not complete synchronization." }, status: :bad_gateway
  end

  def destroy
    @fints_item.destroy_later
    head :accepted
  end

  private

    def set_fints_item
      @fints_item = Current.family.fints_items.active.find(params[:id])
    end

    def require_self_hosted_fints!
      head :not_found unless Rails.application.config.app_mode.self_hosted?
    end

    def fints_item_params
      params.require(:fints_item).permit(:name, :fints_user_id, :customer_id, :pin).tap do |attributes|
        attributes[:user_id] = attributes.delete(:fints_user_id)
      end
    end

    def profile_params
      params.require(:fints_item).permit(:bank_name, :bank_code, :endpoint)
    end

    def render_create_error
      respond_to do |format|
        format.html do
          @fints_item.pin = nil
          render :new, status: :unprocessable_entity
        end
        format.json { render json: { error: @fints_item.errors.full_messages.to_sentence }, status: :unprocessable_entity }
      end
    end

    def serialized_accounts
      @fints_item.fints_accounts.order(:created_at).map do |account|
        {
          id: account.id, name: account.name, account_type: account.remote_account_type,
          currency: account.currency, identifier: account.iban_mask,
          balance: account.balance_available? ? account.current_balance : nil,
          suggested_accountable_type: account.suggested_accountable_type,
          suggested_subtype: account.suggested_subtype,
          supports_holdings: account.holdings_supported?,
          holdings_status: account.holdings_status,
          holdings_synced_on: account.holdings_synced_on,
          mapped_account_id: account.account&.id
        }
      end
    end

    def render_challenge(result, operation:)
      issued = FintsChallenge.issue!(
        result: result,
        operation: operation,
        family: Current.family,
        user: Current.user,
        fints_item: @fints_item
      )
      challenge_path = fints_item_fints_challenge_path(@fints_item, issued.token)
      respond_to do |format|
        format.html { redirect_to challenge_path, status: :see_other }
        format.json do
          render json: {
            status: "challenge_required",
            challenge_type: result.challenge_type,
            challenge_id: issued.token,
            challenge_url: challenge_path
          }, status: :conflict
        end
      end
    end
end
