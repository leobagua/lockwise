# frozen_string_literal: true

module Lockwise
  # Waits on a weak lock until no long transaction uses the tables, then yields
  # inside the same transaction with a lock_timeout. The DDL in the block asks
  # for the lock it needs. The block runs again if that request times out.
  # With access_exclusive: true, ACCESS EXCLUSIVE is taken before the block runs.
  class Lock
    class AttemptFailed < StandardError; end
    private_constant :AttemptFailed

    def initialize(connection, tables, access_exclusive: false,
                   max_pause: 3.0, poll: 0.2, cooldown: 10.0, max_runtime: 120.0)
      @connection = connection
      @tables = Array(tables)
      @blockers = Blockers.new(connection, @tables)
      @access_exclusive = access_exclusive
      @max_pause = max_pause
      @poll = poll
      @cooldown = cooldown
      @max_runtime = max_runtime
    end

    def run(&)
      refuse_open_transaction
      @deadline = monotonic_now + @max_runtime
      begin
        in_transaction(&)
      rescue AttemptFailed
        give_up('attempt_failed') { @blockers.of_any_lock } if monotonic_now + @cooldown >= @deadline
        sleep(@cooldown)
        retry
      end
    end

    private

    # The lock has to own its transaction, so that it can end it at any time.
    def refuse_open_transaction
      return if idle?

      raise TransactionOpenError, 'the connection is already in a transaction'
    end

    def in_transaction(&)
      @connection.exec('BEGIN')
      give_up('prelock_timeout') { @blockers.of_the_weak_lock } unless take_weak_lock
      give_up('long_blockers') { @blockers.older_than(@max_pause) } unless wait_for_long_transactions
      result = with_lock_timeout(&)
      @connection.exec('COMMIT')
      result
    rescue StandardError
      @connection.exec('ROLLBACK') unless idle?
      raise
    end

    def take_weak_lock
      @connection.exec('SET LOCAL statement_timeout = 0')
      limit_lock_wait(@deadline - monotonic_now)
      @connection.exec("LOCK TABLE #{quoted(tables_in_a_stable_order).join(', ')} IN SHARE UPDATE EXCLUSIVE MODE")
      true
    rescue PG::LockNotAvailable
      false
    end

    def wait_for_long_transactions
      loop do
        return true if @blockers.older_than(@max_pause).empty?
        return false if monotonic_now >= @deadline

        sleep(@poll)
      end
    end

    def with_lock_timeout
      if @access_exclusive
        take_access_exclusive
      else
        limit_lock_wait(@max_pause)
      end
      yield
    rescue PG::LockNotAvailable
      # A failed request for ACCESS EXCLUSIVE leaves an xid on the transaction,
      # so the whole transaction ends before the next attempt.
      raise AttemptFailed
    end

    # Locks the tables in the order given. The waits share one pause, so each
    # table gets only the time the tables before it left.
    def take_access_exclusive
      pause_ends_at = monotonic_now + @max_pause
      quoted(@tables).each do |table|
        limit_lock_wait(pause_ends_at - monotonic_now)
        @connection.exec("LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE")
      end
    end

    # Two runs that share tables take the weak locks in the same order, so
    # that they queue instead of deadlocking.
    def tables_in_a_stable_order
      sql = 'SELECT name FROM unnest($1::text[]) AS name ORDER BY name::regclass::oid'
      @connection.exec_params(sql, [PG::TextEncoder::Array.new.encode(@tables)]).column_values(0)
    end

    # The block finds the blockers, and it runs after the transaction has ended.
    def give_up(reason)
      @connection.exec('ROLLBACK') unless idle?
      raise GaveUpError.new(reason, yield)
    end

    def idle?
      @connection.transaction_status == PG::PQTRANS_IDLE
    end

    # Never zero, because Postgres reads a zero lock_timeout as no timeout.
    def limit_lock_wait(seconds)
      @connection.exec("SET LOCAL lock_timeout = '#{[(seconds * 1000).round, 1].max}ms'")
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def quoted(tables)
      tables.map { |table| @connection.quote_ident(table) }
    end
  end
end
