# frozen_string_literal: true

class FintsChallengesController < ApplicationController
  before_action :require_admin!
  before_action :require_self_hosted_fints!
  before_action :set_fints_item
  before_action :set_challenge, only: %i[show cancel]

  def show
    @challenge_token = params[:token]
  end

  def continue
    challenge = FintsChallenge.authorized!(
      token: params[:token],
      family: Current.family,
      user: Current.user,
      fints_item: @fints_item
    )
    tan = validated_tan(challenge)
    return if performed?

    continuation = FintsChallenge.continue!(
      token: params[:token],
      family: Current.family,
      user: Current.user,
      fints_item: @fints_item,
      tan: tan
    )
    render_continuation(continuation)
  rescue FintsChallenge::Expired
    render_expired
  rescue FintsChallenge::Invalid
    render_invalid
  rescue Fints::WorkerClient::Error
    render_terminal_error("The bank confirmation could not be completed.", :bad_gateway)
  ensure
    tan = nil
  end

  def cancel
    @challenge.cancel!
    respond_to do |format|
      format.html { redirect_to accounts_path, notice: t("fints_challenges.cancelled") }
      format.json { head :no_content }
    end
  end

  private

    def set_fints_item
      @fints_item = Current.family.fints_items.active.find(params[:fints_item_id])
    end

    def set_challenge
      @challenge = FintsChallenge.authorized!(
        token: params[:token],
        family: Current.family,
        user: Current.user,
        fints_item: @fints_item
      )
    rescue FintsChallenge::Expired
      render_expired
    rescue FintsChallenge::Invalid
      render_invalid
    end

    def require_self_hosted_fints!
      head :not_found unless Rails.application.config.app_mode.self_hosted?
    end

    def validated_tan(challenge)
      return nil if challenge.challenge_type == "decoupled"

      value = params[:tan].to_s
      unless value.present? && value.bytesize <= 100 && !value.match?(/[[:cntrl:]]/)
        @challenge = challenge
        @challenge_token = params[:token]
        @error_message = t("fints_challenges.show.tan_required")
        render :show, status: :unprocessable_entity
        return nil
      end
      value
    end

    def render_continuation(continuation)
      if continuation.issued
        path = fints_item_fints_challenge_path(@fints_item, continuation.issued.token)
        respond_to do |format|
          format.html { redirect_to path, status: :see_other }
          format.json do
            render json: {
              status: "challenge_required",
              challenge_type: continuation.issued.challenge.challenge_type,
              challenge_id: continuation.issued.token,
              challenge_url: path
            }, status: :conflict
          end
        end
      elsif continuation.result.is_a?(Fints::WorkerClient::Failure)
        render_terminal_error(continuation.result.message, :unprocessable_entity, code: continuation.result.code)
      else
        respond_to do |format|
          format.html { redirect_to accounts_path, notice: t("fints_challenges.completed") }
          format.json { render json: { status: "completed" } }
        end
      end
    end

    def render_expired
      render_terminal_error(t("fints_challenges.expired"), :gone)
    end

    def render_invalid
      render_terminal_error(t("fints_challenges.invalid"), :not_found)
    end

    def render_terminal_error(message, status, code: nil)
      respond_to do |format|
        format.html do
          @challenge = nil
          @error_message = message
          render :show, status: status
        end
        format.json { render json: { error: message, code: code }.compact, status: status }
      end
    end
end
