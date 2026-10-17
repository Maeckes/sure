# frozen_string_literal: true

class FintsItemsController < ApplicationController
  before_action :require_admin!
  before_action :require_self_hosted_fints!
  before_action :set_fints_item, except: :create

  def create
    item = Current.family.fints_items.create!(fints_item_params)
    render json: { id: item.id, status: item.status }, status: :created
  rescue ActiveRecord::RecordInvalid => error
    render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def discover
    result = @fints_item.discover_accounts!
    case result
    when Fints::WorkerClient::Success
      render json: { accounts: serialized_accounts }
    when Fints::WorkerClient::Challenge
      render_challenge(result, operation: :discover)
    when Fints::WorkerClient::Failure
      render json: { error: result.message, code: result.code }, status: :unprocessable_entity
    end
  rescue Fints::WorkerClient::Error
    render json: { error: "The FinTS worker could not complete discovery." }, status: :bad_gateway
  end

  def accounts
    render json: { accounts: serialized_accounts }
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
    render json: { account_id: linked.id, fints_account_id: remote.id }, status: :created
  rescue ActiveRecord::RecordInvalid, ArgumentError => error
    render json: { error: error.message }, status: :unprocessable_entity
  end

  def sync
    result = @fints_item.import_latest_fints_data
    case result
    when Fints::WorkerClient::Challenge
      render_challenge(result, operation: :transactions)
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
      params.require(:fints_item).permit(:name, :bank_name, :bank_code, :endpoint, :fints_user_id, :customer_id, :pin).tap do |attributes|
        attributes[:user_id] = attributes.delete(:fints_user_id)
      end
    end

    def serialized_accounts
      @fints_item.fints_accounts.order(:created_at).map do |account|
        {
          id: account.id, name: account.name, account_type: account.remote_account_type,
          currency: account.currency, identifier: account.iban_mask,
          balance: account.balance_available? ? account.current_balance : nil,
          suggested_subtype: account.suggested_subtype, mapped_account_id: account.account&.id
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
