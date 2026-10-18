# frozen_string_literal: true

class FintsItem < ApplicationRecord
  include Syncable, Unlinking, Encryptable, DestroyableLater

  attr_accessor :profile_id

  def self.encryption_ready?
    ActiveRecordEncryptionConfig.ready?
  end

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :user_id
    encrypts :customer_id
    encrypts :pin
    encrypts :client_state
    encrypts :private_state
  end

  belongs_to :family
  has_many :fints_accounts, dependent: :destroy
  has_many :fints_challenges, dependent: :destroy
  has_many :accounts, through: :fints_accounts

  validates :name, :bank_name, :bank_code, :endpoint, :user_id, :pin, presence: true
  validates :bank_code, format: { with: /\A\d{8}\z/ }
  validate :endpoint_is_safe_https
  validate :active_record_encryption_is_configured
  validate :self_hosted_installation

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { Rails.application.config.app_mode.self_hosted? ? active : none }
  scope :ordered, -> { order(created_at: :desc) }

  def credentials_configured?
    user_id.present? && pin.present?
  end

  def discover_accounts!(worker: Fints::WorkerClient.new)
    FintsItem::Importer.new(self, worker: worker).discover
  end

  def import_latest_fints_data(worker: Fints::WorkerClient.new)
    FintsItem::Importer.new(self, worker: worker).import
  end

  def continue_fints_challenge!(operation:, worker_state:, tan:, worker: Fints::WorkerClient.new)
    FintsItem::Importer.new(self, worker: worker).continue(
      operation: operation,
      worker_state: worker_state,
      tan: tan
    )
  end

  def process_accounts
    fints_accounts.joins(:account_provider).map do |fints_account|
      FintsAccount::Processor.new(fints_account).process
    rescue StandardError => error
      DebugLogEntry.capture(
        category: "provider_sync_error", level: "error", message: "FinTS account processing failed",
        source: self.class.name, provider_key: "fints", family: family,
        account_provider: fints_account.account_provider,
        metadata: { fints_item_id: id, fints_account_id: fints_account.id, error_class: error.class.name }
      )
      { success: false }
    end
  end

  private

    def endpoint_is_safe_https
      Fints::EndpointValidator.validate!(endpoint) if endpoint.present?
    rescue Fints::EndpointValidator::InvalidEndpoint => error
      errors.add(:endpoint, error.message)
    end

    def active_record_encryption_is_configured
      errors.add(:base, "Active Record encryption must be configured for FinTS") unless self.class.encryption_ready?
    end

    def self_hosted_installation
      errors.add(:base, "FinTS is available only in self-hosted installations") unless Rails.application.config.app_mode.self_hosted?
    end
end
