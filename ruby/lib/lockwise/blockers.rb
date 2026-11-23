# frozen_string_literal: true

module Lockwise
  # Finds the sessions that hold locks on a table.
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
         AND pg_locks.relation = $1::regclass
         AND pg_locks.granted
         AND pg_locks.pid <> pg_backend_pid()
         AND pg_locks.mode = ANY($2::text[])
         AND pg_stat_activity.xact_start <= clock_timestamp() - make_interval(secs => $3)
       GROUP BY pg_stat_activity.pid, pg_stat_activity.application_name,
                pg_stat_activity.backend_type, pg_stat_activity.xact_start
    SQL

    def initialize(connection, table)
      @connection = connection
      @table = table
    end

    def of_the_weak_lock
      find(WEAK_LOCK_CONFLICTS, 0)
    end

    def of_any_lock
      find(EVERY_LOCK, 0)
    end

    def older_than(seconds)
      find(EVERY_LOCK, seconds)
    end

    private

    def find(modes, minimum_age)
      # Inside a transaction, pg_stat_activity is frozen at its first read.
      @connection.exec('SELECT pg_stat_clear_snapshot()')
      @connection.exec_params(QUERY, [@table, modes, minimum_age]).map do |row|
        Blocker.new(row['pid'].to_i, row['application_name'], row['backend_type'], row['age'].to_f)
      end
    end
  end
end
