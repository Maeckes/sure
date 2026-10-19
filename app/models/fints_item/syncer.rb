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

    schedule_results = fints_item.schedule_account_syncs(
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )
    if schedule_results.any? { _1[:success] == false }
      raise Fints::WorkerClient::Error, "FinTS account synchronization could not be scheduled"
    end
  end

  def perform_post_sync; end
end
