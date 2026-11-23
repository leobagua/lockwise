# frozen_string_literal: true

module Lockwise
  # Waits on a weak lock until no long transaction uses the tables, then yields
  # inside the same transaction with a lock_timeout. The DDL in the block asks
  # for the lock it needs. The block runs again if that request times out.
  # With access_exclusive: true or share_row_exclusive: true, that lock is
  # taken before the block runs, on the tables in the order given.
  class Lock
    # Ends the transaction and starts again from the weak lock. The message is the reason.
    class StartOver < StandardError; end
    # Ends the transaction for good. The message is the reason.
    class GiveUp < StandardError; end
    private_constant :StartOver, :GiveUp

    def initialize(connection, tables, access_exclusive: false, share_row_exclusive: false,
                   max_pause: 3.0, poll: 0.2, cooldown: 10.0, weak_lock_hold: 60.0, max_runtime: 120.0)
      @connection = Adapters.for(connection)
      @tables = Array(tables)
      @blockers = Blockers.new(@connection, @tables, max_pause)
      @explicit_lock = explicit_lock(access_exclusive, share_row_exclusive)
      @max_pause = max_pause
      @poll = poll
      @cooldown = cooldown
      @weak_lock_hold = weak_lock_hold
      @max_runtime = max_runtime
    end

    def run(&)
      refuse_open_transaction
      @deadline = monotonic_now + @max_runtime
      attempt(&)
    end

    private

    def attempt(&)
      @connection.transaction { lock_and_run(&) }
    rescue StartOver => e
      raise gave_up(e.message) if monotonic_now + @cooldown >= @deadline

      sleep(@cooldown)
      retry
    rescue GiveUp => e
      raise gave_up(e.message)
    end

    # The lock has to own its transaction, so that it can end it at any time.
    def refuse_open_transaction
      return if @connection.idle?

      raise TransactionOpenError, 'the connection is already in a transaction'
    end

    def lock_and_run(&)
      raise GiveUp, 'prelock_timeout' unless take_weak_lock

      wait_for_long_transactions
      @connection.execute("SET LOCAL statement_timeout = '#{@statement_timeout}'")
      with_lock_timeout(&)
    end

    # The wait for the weak lock has no time limit of its own, so the
    # statement_timeout is off until the block is about to run.
    def take_weak_lock
      @statement_timeout = @connection.select('SHOW statement_timeout', []).first['statement_timeout']
      @connection.execute('SET LOCAL statement_timeout = 0')
      limit_lock_wait(@deadline - monotonic_now)
      @connection.execute("LOCK TABLE #{quoted(tables_in_a_stable_order).join(', ')} IN SHARE UPDATE EXCLUSIVE MODE")
      true
    rescue *@connection.lock_timeout_errors
      false
    end

    # The weak lock keeps VACUUM, ANALYZE and concurrent index builds out, so
    # it is released after weak_lock_hold to give them a turn.
    def wait_for_long_transactions
      release_weak_lock_at = monotonic_now + @weak_lock_hold
      until @blockers.long_transactions.empty?
        raise GiveUp, 'long_blockers' if monotonic_now >= @deadline
        raise StartOver, 'long_blockers' if monotonic_now >= release_weak_lock_at

        sleep(@poll)
      end
    end

    def with_lock_timeout
      if @explicit_lock
        take_explicit_lock
      else
        limit_lock_wait(@max_pause)
      end
      yield
    rescue *@connection.lock_timeout_errors
      # A failed request for ACCESS EXCLUSIVE leaves an xid on the transaction,
      # so the whole transaction ends before the next attempt.
      raise StartOver, 'attempt_failed'
    end

    # Locks the tables in the order given. The waits share one pause, so each
    # table gets only the time the tables before it left.
    def take_explicit_lock
      pause_ends_at = monotonic_now + @max_pause
      quoted(@tables).each do |table|
        limit_lock_wait(pause_ends_at - monotonic_now)
        @connection.execute("LOCK TABLE #{table} IN #{@explicit_lock} MODE")
      end
    end

    def explicit_lock(access_exclusive, share_row_exclusive)
      if access_exclusive && share_row_exclusive
        raise ArgumentError, 'choose access_exclusive or share_row_exclusive, not both'
      end

      return 'ACCESS EXCLUSIVE' if access_exclusive

      'SHARE ROW EXCLUSIVE' if share_row_exclusive
    end

    # Two runs that share tables take the weak locks in the same order, so
    # that they queue instead of deadlocking.
    def tables_in_a_stable_order
      sql = 'SELECT name FROM unnest($1::text[]) AS name ORDER BY name::regclass::oid'
      @connection.select(sql, [PG::TextEncoder::Array.new.encode(@tables)]).map { |row| row['name'] }
    end

    # Called after the transaction has ended, so the blockers are looked up outside it.
    def gave_up(reason)
      GaveUpError.new(reason, @blockers.behind(reason))
    end

    # Never zero, because Postgres reads a zero lock_timeout as no timeout.
    def limit_lock_wait(seconds)
      @connection.execute("SET LOCAL lock_timeout = '#{[(seconds * 1000).round, 1].max}ms'")
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def quoted(tables)
      tables.map { |table| @connection.quote(table) }
    end
  end
end
