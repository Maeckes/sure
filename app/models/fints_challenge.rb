# frozen_string_literal: true

require "base64"
require "digest"

class FintsChallenge < ApplicationRecord
  include Encryptable

  def self.encryption_ready?
    ActiveRecordEncryptionConfig.ready?
  end

  TTL = 5.minutes
  OPERATIONS = %w[test discover transactions holdings].freeze
  TYPES = %w[tan decoupled].freeze

  Issued = Data.define(:challenge, :token)
  State = Data.define(:operation, :worker_state, :expires_at)
  Continuation = Data.define(:result, :issued)

  Expired = Class.new(StandardError)
  Invalid = Class.new(StandardError)

  if encryption_ready?
    encrypts :message
    encrypts :challenge_html
    encrypts :challenge_image
    encrypts :worker_state
  end

  belongs_to :family
  belongs_to :user
  belongs_to :fints_item

  validates :token_digest, presence: true, uniqueness: true
  validates :operation, inclusion: { in: OPERATIONS }
  validates :challenge_type, inclusion: { in: TYPES }
  validates :message, :worker_state, :expires_at, presence: true
  validate :associations_share_family
  validate :active_record_encryption_is_configured
  validate :bounded_payload

  scope :expired, -> { where("expires_at <= ?", Time.current) }

  class << self
    def issue!(result:, operation:, family:, user:, fints_item:, expires_at: TTL.from_now)
      raise Invalid, "Invalid FinTS challenge" unless result.is_a?(Fints::WorkerClient::Challenge)
      raise Invalid, "Invalid FinTS challenge" unless operation.to_s.in?(OPERATIONS)

      token = SecureRandom.urlsafe_base64(32)
      where(fints_item: fints_item).expired.delete_all
      challenge = create!(
        family: family,
        user: user,
        fints_item: fints_item,
        token_digest: digest(token),
        operation: operation,
        challenge_type: result.challenge_type,
        message: result.message,
        challenge_html: result.challenge_html,
        challenge_image: result.challenge_image,
        worker_state: result.worker_state,
        expires_at: expires_at
      )
      Issued.new(challenge, token)
    end

    def authorized!(token:, family:, user:, fints_item:)
      challenge = find_by!(
        token_digest: digest(token),
        family: family,
        user: user,
        fints_item: fints_item
      )
      challenge.expire_if_needed!
      challenge
    rescue ActiveRecord::RecordNotFound
      raise Invalid, "FinTS challenge is invalid"
    end

    def continue!(token:, family:, user:, fints_item:, tan: nil, worker: Fints::WorkerClient.new)
      challenge = authorized!(token: token, family: family, user: user, fints_item: fints_item)
      state = challenge.consume!
      result = fints_item.continue_fints_challenge!(
        operation: state.operation,
        worker_state: state.worker_state,
        tan: tan,
        worker: worker
      )
      issued = if result.is_a?(Fints::WorkerClient::Challenge)
        issue!(
          result: result,
          operation: state.operation,
          family: family,
          user: user,
          fints_item: fints_item,
          expires_at: state.expires_at
        )
      end
      Continuation.new(result, issued)
    ensure
      tan = nil
    end

    def digest(token)
      value = token.to_s
      raise Invalid, "FinTS challenge is invalid" unless value.match?(/\A[A-Za-z0-9_-]{40,100}\z/)

      Digest::SHA256.hexdigest(value)
    end
  end

  def consume!
    state = nil
    expired_during_claim = false
    transaction do
      lock!
      if expires_at.future?
        state = State.new(operation, worker_state, expires_at)
      else
        expired_during_claim = true
      end
      destroy!
    end
    raise Expired, "FinTS challenge has expired" if expired_during_claim

    state
  rescue ActiveRecord::RecordNotFound, ActiveRecord::StaleObjectError
    raise Invalid, "FinTS challenge is invalid"
  end

  def cancel!
    destroy!
  end

  def expire_if_needed!
    return if expires_at.future?

    destroy!
    raise Expired, "FinTS challenge has expired"
  end

  private

    def associations_share_family
      errors.add(:user, "must belong to the same family") if user && user.family_id != family_id
      errors.add(:fints_item, "must belong to the same family") if fints_item && fints_item.family_id != family_id
    end

    def active_record_encryption_is_configured
      errors.add(:base, "Active Record encryption must be configured for FinTS") unless self.class.encryption_ready?
    end

    def bounded_payload
      errors.add(:message, "is too large") if message.to_s.bytesize > 5_000
      errors.add(:challenge_html, "is too large") if challenge_html.to_s.bytesize > 20_000
      errors.add(:worker_state, "is too large") if worker_state.to_s.bytesize > 2.megabytes
      errors.add(:challenge_image, "is invalid") unless valid_challenge_image?
    end

    def valid_challenge_image?
      return true if challenge_image.blank?
      return false if challenge_image.bytesize > 2.megabytes

      match = challenge_image.match(%r{\Adata:(image/(?:png|jpeg));base64,([A-Za-z0-9+/=]+)\z})
      match && Base64.strict_decode64(match[2]).bytesize <= 1.megabyte
    rescue ArgumentError
      false
    end
end
