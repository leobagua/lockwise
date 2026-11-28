# frozen_string_literal: true

module Lockwise
  class Error < StandardError; end
  class TransactionOpenError < Error; end

  # started tells one transaction of a session from the next. A regular
  # autovacuum yields to the weak lock, so nobody has to wait for it.
  Blocker = Struct.new(:pid, :application, :backend_type, :age, :started, :yields_to_weak_lock)

  # Raised when the time runs out before the strong lock could be asked for.
  class GaveUpError < Error
    attr_reader :reason, :blockers

    def initialize(reason, blockers)
      @reason = reason
      @blockers = blockers
      super("gave up (#{reason}), blocked by #{describe_blockers}")
    end

    private

    def describe_blockers
      return 'no session in sight' if blockers.empty?

      blockers.map { |blocker| "#{name_of(blocker)} (#{blocker.backend_type}, #{blocker.age.round(1)}s)" }.join(', ')
    end

    # A prepared transaction has no pid. Its application is its identifier.
    def name_of(blocker)
      blocker.pid ? "pid #{blocker.pid}" : blocker.application
    end
  end
end
