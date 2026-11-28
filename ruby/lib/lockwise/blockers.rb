# frozen_string_literal: true

module Lockwise
  # Finds the sessions that hold locks on the tables, or on their partitions.
  class Blockers
    WEAK_LOCK_CONFLICTS =
      '{ShareUpdateExclusiveLock,ShareLock,ShareRowExclusiveLock,ExclusiveLock,AccessExclusiveLock}'
    # The lock the DDL will ask for is unknown, so any holder may be in its way.
    EVERY_LOCK = "{AccessShareLock,RowShareLock,RowExclusiveLock,#{WEAK_LOCK_CONFLICTS.delete('{}')}}".freeze
    # When the caller names the lock, only the modes that conflict with it count.
    CONFLICTS = {
      'SHARE ROW EXCLUSIVE' => "{RowExclusiveLock,#{WEAK_LOCK_CONFLICTS.delete('{}')}}"
    }.freeze

    # A prepared transaction keeps its locks without a session, so it is not in
    # pg_stat_activity. Its locks have no pid, and its transactionid lock leads
    # to pg_prepared_xacts. pg_locks is read once, because each read is costly.
    QUERY = <<~SQL
      WITH all_locks AS MATERIALIZED (
        SELECT pg_locks.locktype, pg_locks.database, pg_locks.relation, pg_locks.transactionid,
               pg_locks.virtualtransaction, pg_locks.pid, pg_locks.mode, pg_locks.granted
          FROM pg_locks
      ),
      table_locks AS (
        SELECT all_locks.pid, all_locks.virtualtransaction
          FROM all_locks
         WHERE all_locks.locktype = 'relation'
           AND all_locks.database = (SELECT pg_database.oid FROM pg_database WHERE pg_database.datname = current_database())
           AND all_locks.relation IN (
                 SELECT target FROM unnest($1::regclass[]) AS target
                 UNION
                 SELECT pg_partition_tree.relid FROM unnest($1::regclass[]) AS target, pg_partition_tree(target)
               )
           AND all_locks.granted
           AND all_locks.pid IS DISTINCT FROM pg_backend_pid()
           AND all_locks.mode = ANY($2::text[])
      )
      SELECT pg_stat_activity.pid,
             pg_stat_activity.application_name,
             pg_stat_activity.backend_type,
             extract(epoch FROM clock_timestamp() - pg_stat_activity.xact_start) AS age
        FROM table_locks
        JOIN pg_stat_activity ON pg_stat_activity.pid = table_locks.pid
       WHERE pg_stat_activity.xact_start <= clock_timestamp() - make_interval(secs => $3)
       GROUP BY pg_stat_activity.pid, pg_stat_activity.application_name,
                pg_stat_activity.backend_type, pg_stat_activity.xact_start
      UNION ALL
      SELECT NULL::integer,
             pg_prepared_xacts.gid,
             'prepared transaction',
             extract(epoch FROM clock_timestamp() - pg_prepared_xacts.prepared)
        FROM table_locks
        JOIN all_locks ON all_locks.virtualtransaction = table_locks.virtualtransaction
                      AND all_locks.locktype = 'transactionid'
        JOIN pg_prepared_xacts ON pg_prepared_xacts.transaction = all_locks.transactionid
       WHERE table_locks.pid IS NULL
         AND pg_prepared_xacts.prepared <= clock_timestamp() - make_interval(secs => $3)
       GROUP BY pg_prepared_xacts.gid, pg_prepared_xacts.prepared
    SQL

    def initialize(connection, tables, max_pause, explicit_lock)
      @connection = connection
      @tables = PG::TextEncoder::Array.new.encode(tables)
      @max_pause = max_pause
      @conflicts = CONFLICTS.fetch(explicit_lock, EVERY_LOCK)
    end

    # Transactions that would keep the tables paused for longer than allowed.
    def long_transactions
      find(@conflicts, @max_pause)
    end

    # The sessions to name when the lock gives up for the given reason.
    def behind(reason)
      case reason
      when 'prelock_timeout' then find(WEAK_LOCK_CONFLICTS, 0)
      when 'long_blockers' then long_transactions
      else find(@conflicts, 0)
      end
    end

    private

    def find(modes, minimum_age)
      # Inside a transaction, pg_stat_activity is frozen at its first read.
      @connection.execute('SELECT pg_stat_clear_snapshot()')
      @connection.select(QUERY, [@tables, modes, minimum_age]).map do |row|
        Blocker.new(row['pid']&.to_i, row['application_name'], row['backend_type'], row['age'].to_f)
      end
    end
  end
end
