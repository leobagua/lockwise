# frozen_string_literal: true

module Lockwise
  # Waits, holding no lock, until no long transaction uses the tables. Then, in
  # one short transaction, takes a weak lock and yields with a lock_timeout.
  # The DDL in the block asks for the lock it needs. When a lock request times
  # out, the transaction ends and the run starts over from the wait.
  # With access_exclusive_in_order: true or share_row_exclusive_in_order: true, that lock is
  # taken before the block runs, on the tables in the order of the list.
  class Lock
    # Ends the transaction and starts again from the wait. The message is the reason.
    class StartOver < StandardError; end
    # Ends the run for good. The message is the reason.
    class GiveUp < StandardError; end
    private_constant :StartOver, :GiveUp

    # Postgres cancels a regular autovacuum when a session has waited for
    # deadlock_timeout behind it. The weak lock waits a little longer than that.
    WEAK_LOCK_MARGIN = 0.5

    def initialize(connection, tables, access_exclusive_in_order: false, share_row_exclusive_in_order: false,
                   max_pause: 3.0, poll: 0.2, cooldown: 10.0, max_runtime: 120.0)
      @connection = Adapters.for(connection)
      @tables = Tables.new(@connection, tables)
      @explicit_lock = explicit_lock(access_exclusive_in_order, share_row_exclusive_in_order)
      @blockers = Blockers.new(@connection, @tables.names, max_pause, @explicit_lock)
      @max_pause = max_pause
      @poll = poll
      @cooldown = cooldown
      @max_runtime = max_runtime
    end

    def run(&)
      refuse_open_transaction
      @deadline = monotonic_now + @max_runtime
      attempt(&)
    end

    private

    def attempt(&)
      wait_until_clear
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

    # Holds no lock and no transaction. pg_locks is read once per round, and
    # the wait itself only polls pg_stat_activity.
    def wait_until_clear
      loop do
        long_transactions = @blockers.long_transactions
        return if long_transactions.empty?

        until @blockers.gone?(long_transactions)
          raise GiveUp, 'long_blockers' if monotonic_now >= @deadline

          sleep(@poll)
        end
      end
    end

    def lock_and_run(&)
      raise StartOver, 'prelock_timeout' unless take_weak_lock

      @connection.execute("SET LOCAL statement_timeout = '#{@statement_timeout}'")
      with_lock_timeout(&)
    end

    # The statement_timeout is off while the weak lock waits, and comes back
    # before the block runs.
    def take_weak_lock
      @statement_timeout = @connection.select('SHOW statement_timeout', []).first['statement_timeout']
      @connection.execute('SET LOCAL statement_timeout = 0')
      limit_lock_wait([deadlock_timeout + WEAK_LOCK_MARGIN, @deadline - monotonic_now].min)
      @connection.execute("LOCK TABLE #{@tables.in_a_stable_order.join(', ')} IN SHARE UPDATE EXCLUSIVE MODE")
      true
    rescue *@connection.lock_timeout_errors
      false
    end

    def deadlock_timeout
      sql = "SELECT pg_settings.setting FROM pg_settings WHERE pg_settings.name = 'deadlock_timeout'"
      @deadlock_timeout ||= @connection.select(sql, []).first['setting'].to_f / 1000
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
      @tables.in_list_order.each do |table|
        limit_lock_wait(pause_ends_at - monotonic_now)
        @connection.execute("LOCK TABLE #{table} IN #{@explicit_lock} MODE")
      end
    end

    def explicit_lock(access_exclusive_in_order, share_row_exclusive_in_order)
      if access_exclusive_in_order && share_row_exclusive_in_order
        raise ArgumentError, 'choose access_exclusive_in_order or share_row_exclusive_in_order, not both'
      end

      return 'ACCESS EXCLUSIVE' if access_exclusive_in_order

      'SHARE ROW EXCLUSIVE' if share_row_exclusive_in_order
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
  end
end
