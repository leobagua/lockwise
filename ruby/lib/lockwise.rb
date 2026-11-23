# frozen_string_literal: true

require_relative 'lockwise/version'
require_relative 'lockwise/errors'
require_relative 'lockwise/blockers'
require_relative 'lockwise/lock'

# Takes strong locks on hot Postgres tables with one bounded pause.
module Lockwise
  def self.with_lock(connection, tables, **options, &)
    Lock.new(connection, tables, **options).run(&)
  end
end
