# frozen_string_literal: true

module Lockwise
  # Waits on a weak lock until no long transaction uses the table, then takes
  # ACCESS EXCLUSIVE once and yields inside the same transaction.
  class Lock
    WEAK_LOCK_CONFLICTS =
      '{ShareUpdateExclusiveLock,ShareLock,ShareRowExclusiveLock,ExclusiveLock,AccessExclusiveLock}'
    STRONG_LOCK_CONFLICTS =
      "{AccessShareLock,RowShareLock,RowExclusiveLock,#{WEAK_LOCK_CONFLICTS.delete('{}')}}".freeze

    BLOCKERS = <<~SQL
      SELECT pg_stat_activity.pid,
             pg_stat_activity.application_name,
             pg_stat_activity.backend_type,
             extract(epoch FROM clock_timestamp() - pg_stat_activity.xact_start) AS age
        FROM pg_locks
        JOIN pg_stat_activity ON pg_stat_activity.pid = pg_locks.pid
       WHERE pg_locks.locktype = 'relation'
         AND pg_locks.relation = $1::regclass
         AND pg_locks.granted
         AND pg_locks.pid <> pg_backend_pid()
         AND pg_locks.mode = ANY($2::text[])
         AND pg_stat_activity.xact_start <= clock_timestamp() - make_interval(secs => $3)
       GROUP BY pg_stat_activity.pid, pg_stat_activity.application_name,
                pg_stat_activity.backend_type, pg_stat_activity.xact_start
    SQL

    def initialize(connection, table, max_pause: 3.0, poll: 0.2, max_runtime: 120.0)
      @connection = connection
      @table = table
      @max_pause = max_pause
      @poll = poll
      @max_runtime = max_runtime
    end

    def run(&)
      refuse_open_transaction
      @deadline = monotonic_now + @max_runtime
      in_transaction(&)
    end

    private

    # The lock has to own its transaction, so that it can end it at any time.
    def refuse_open_transaction
      return if idle?

      raise TransactionOpenError, 'the connection is already in a transaction'
    end

    def in_transaction
      @connection.exec('BEGIN')
      give_up('prelock_timeout', WEAK_LOCK_CONFLICTS, 0) unless take_weak_lock
      give_up('long_blockers', STRONG_LOCK_CONFLICTS, @max_pause) unless wait_for_long_transactions
      take_strong_lock
      result = yield
      @connection.exec('COMMIT')
      result
    rescue StandardError
      @connection.exec('ROLLBACK') unless idle?
      raise
    end

    def take_weak_lock
      @connection.exec('SET LOCAL statement_timeout = 0')
      @connection.exec("SET LOCAL lock_timeout = '#{milliseconds(@deadline - monotonic_now)}ms'")
      @connection.exec("LOCK TABLE #{quoted_table} IN SHARE UPDATE EXCLUSIVE MODE")
      true
    rescue PG::LockNotAvailable
      false
    end

    def wait_for_long_transactions
      loop do
        return true if blockers(STRONG_LOCK_CONFLICTS, @max_pause).empty?
        return false if monotonic_now >= @deadline

        sleep(@poll)
      end
    end

    def take_strong_lock
      @connection.exec("SET LOCAL lock_timeout = '#{milliseconds(@max_pause)}ms'")
      @connection.exec("LOCK TABLE #{quoted_table} IN ACCESS EXCLUSIVE MODE")
    end

    def give_up(reason, modes, minimum_age)
      @connection.exec('ROLLBACK')
      raise GaveUpError.new(reason, blockers(modes, minimum_age))
    end

    def blockers(modes, minimum_age)
      @connection.exec_params(BLOCKERS, [@table, modes, minimum_age]).map do |row|
        Blocker.new(row['pid'].to_i, row['application_name'], row['backend_type'], row['age'].to_f)
      end
    end

    def idle?
      @connection.transaction_status == PG::PQTRANS_IDLE
    end

    # Never zero, because Postgres reads a zero lock_timeout as no timeout.
    def milliseconds(seconds)
      [(seconds * 1000).round, 1].max
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def quoted_table
      @connection.quote_ident(@table)
    end
  end
end
