module Family::FintsConnectable
  extend ActiveSupport::Concern

  included do
    has_many :fints_items, dependent: :destroy
    has_many :fints_challenges, dependent: :destroy
  end
end
