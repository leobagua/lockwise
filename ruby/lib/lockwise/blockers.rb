# frozen_string_literal: true

module Lockwise
  # Finds the sessions that hold locks on the tables.
  class Blockers
    WEAK_LOCK_CONFLICTS =
      '{ShareUpdateExclusiveLock,ShareLock,ShareRowExclusiveLock,ExclusiveLock,AccessExclusiveLock}'
    # The lock the DDL will ask for is unknown, so any holder may be in its way.
    EVERY_LOCK = "{AccessShareLock,RowShareLock,RowExclusiveLock,#{WEAK_LOCK_CONFLICTS.delete('{}')}}".freeze

    QUERY = <<~SQL
      SELECT pg_stat_activity.pid,
             pg_stat_activity.application_name,
             pg_stat_activity.backend_type,
             extract(epoch FROM clock_timestamp() - pg_stat_activity.xact_start) AS age
        FROM pg_locks
        JOIN pg_stat_activity ON pg_stat_activity.pid = pg_locks.pid
       WHERE pg_locks.locktype = 'relation'
         AND pg_locks.relation = ANY($1::regclass[])
         AND pg_locks.granted
         AND pg_locks.pid <> pg_backend_pid()
         AND pg_locks.mode = ANY($2::text[])
         AND pg_stat_activity.xact_start <= clock_timestamp() - make_interval(secs => $3)
       GROUP BY pg_stat_activity.pid, pg_stat_activity.application_name,
                pg_stat_activity.backend_type, pg_stat_activity.xact_start
    SQL

    def initialize(connection, tables, max_pause)
      @connection = connection
      @tables = PG::TextEncoder::Array.new.encode(tables)
      @max_pause = max_pause
    end

    # Transactions that would keep the tables paused for longer than allowed.
    def long_transactions
      find(EVERY_LOCK, @max_pause)
    end

    # The sessions to name when the lock gives up for the given reason.
    def behind(reason)
      case reason
      when 'prelock_timeout' then find(WEAK_LOCK_CONFLICTS, 0)
      when 'long_blockers' then long_transactions
      else find(EVERY_LOCK, 0)
      end
    end

    private

    def find(modes, minimum_age)
      # Inside a transaction, pg_stat_activity is frozen at its first read.
      @connection.execute('SELECT pg_stat_clear_snapshot()')
      @connection.select(QUERY, [@tables, modes, minimum_age]).map do |row|
        Blocker.new(row['pid'].to_i, row['application_name'], row['backend_type'], row['age'].to_f)
      end
    end
  end
end
