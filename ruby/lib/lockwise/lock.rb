# frozen_string_literal: true

module Lockwise
  # Waits on a weak lock until no long transaction uses the table, then takes
  # ACCESS EXCLUSIVE once and yields inside the same transaction.
  class Lock
    LONG_TRANSACTIONS = <<~SQL
      SELECT count(*)
        FROM pg_locks
        JOIN pg_stat_activity ON pg_stat_activity.pid = pg_locks.pid
       WHERE pg_locks.locktype = 'relation'
         AND pg_locks.relation = $1::regclass
         AND pg_locks.granted
         AND pg_locks.pid <> pg_backend_pid()
         AND pg_stat_activity.xact_start < clock_timestamp() - make_interval(secs => $2)
    SQL

    def initialize(connection, table, max_pause: 3.0, poll: 0.2)
      @connection = connection
      @table = table
      @max_pause = max_pause
      @poll = poll
    end

    def run(&)
      refuse_open_transaction
      in_transaction(&)
    end

    private

    # The lock has to own its transaction, so that it can end it at any time.
    def refuse_open_transaction
      return if @connection.transaction_status == PG::PQTRANS_IDLE

      raise TransactionOpenError, 'the connection is already in a transaction'
    end

    def in_transaction
      @connection.exec('BEGIN')
      take_weak_lock
      sleep(@poll) while long_transactions?
      take_strong_lock
      result = yield
      @connection.exec('COMMIT')
      result
    rescue StandardError
      @connection.exec('ROLLBACK')
      raise
    end

    def take_weak_lock
      @connection.exec('SET LOCAL statement_timeout = 0')
      @connection.exec("LOCK TABLE #{quoted_table} IN SHARE UPDATE EXCLUSIVE MODE")
    end

    def long_transactions?
      @connection.exec_params(LONG_TRANSACTIONS, [@table, @max_pause]).getvalue(0, 0).to_i.positive?
    end

    def take_strong_lock
      @connection.exec("SET LOCAL lock_timeout = '#{(@max_pause * 1000).round}ms'")
      @connection.exec("LOCK TABLE #{quoted_table} IN ACCESS EXCLUSIVE MODE")
    end

    def quoted_table
      @connection.quote_ident(@table)
    end
  end
end
