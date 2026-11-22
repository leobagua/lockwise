# frozen_string_literal: true

require_relative 'lockwise/version'
require_relative 'lockwise/lock'

# Takes strong locks on hot Postgres tables with one bounded pause.
module Lockwise
  class Error < StandardError; end
  class TransactionOpenError < Error; end

  def self.with_lock(connection, table, **options, &)
    Lock.new(connection, table, **options).run(&)
  end
end
