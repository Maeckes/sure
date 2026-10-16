# frozen_string_literal: true

class FintsItem::Syncer
  attr_reader :fints_item

  def initialize(fints_item)
    @fints_item = fints_item
  end

  def perform_sync(sync)
    result = fints_item.import_latest_fints_data
    case result
    when Fints::WorkerClient::Challenge
      sync.update!(status_text: "Bank confirmation required") if sync.respond_to?(:status_text)
      return
    when Fints::WorkerClient::Failure
      raise Fints::WorkerClient::Error, result.message
    end
    raise Fints::WorkerClient::Error, "FinTS synchronization failed" if result.is_a?(Hash) && !result[:success]
  end

  def perform_post_sync; end
end
