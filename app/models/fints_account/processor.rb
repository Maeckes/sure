# frozen_string_literal: true

class FintsAccount::Processor
  attr_reader :fints_account

  def initialize(fints_account)
    @fints_account = fints_account
  end

  def process(transactions = [])
    return { success: true, total: 0, imported: 0 } unless fints_account.account

    update_balance if fints_account.balance_available?
    imported = transactions.count { FintsEntry::Processor.new(_1, fints_account: fints_account).process }
    { success: true, total: transactions.size, imported: imported }
  end

  private

    def update_balance
      account = fints_account.account
      account.update!(currency: fints_account.currency, cash_balance: fints_account.current_balance)
      result = account.set_current_balance(fints_account.current_balance)
      raise "Could not set FinTS account balance" unless result.success?
    end
end
