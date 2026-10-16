# frozen_string_literal: true

class FintsItem::SyncCompleteEvent
  def initialize(fints_item)
    @fints_item = fints_item
  end

  def broadcast
    @fints_item.accounts.each(&:broadcast_sync_complete)
    @fints_item.family.broadcast_sync_complete
  end
end
