# frozen_string_literal: true

# Helpers that talk to the throwaway Postgres started by bin/test.
module Database
  def connect(database: nil)
    settings = ENV.fetch('LOCKWISE_TEST_CONN') { raise 'run the specs through bin/test' }
    settings = settings.sub(/dbname=\S+/, "dbname=#{database}") if database
    PG.connect(settings)
  end

  ROW_LOCK = 'UPDATE accounts SET id = id WHERE id = 1'
  WEAK_LOCK = 'LOCK TABLE accounts IN SHARE UPDATE EXCLUSIVE MODE'

  # Opens a transaction that runs the given statement and stays open until
  # something is pushed to the returned queue. Also returns its backend pid.
  def open_transaction(statement = ROW_LOCK, before: nil)
    release = Queue.new
    started = Queue.new
    thread = Thread.new { hold_transaction(statement, before, started, release) }
    [release, thread, started.pop]
  end

  # Returns a thread whose value is the time the transaction was released.
  def release_after(release, seconds)
    Thread.new do
      sleep seconds
      release.push(true)
      monotonic_now
    end
  end

  # Runs Lockwise.with_lock in a thread, with its own connection.
  # The value of the thread is the time the statement ran.
  def lock_in_background(tables, statement, **options)
    Thread.new do
      background = connect
      ran_at = Lockwise.with_lock(background, tables, **options) do
        background.exec(statement)
        monotonic_now
      end
      background.close
      ran_at
    end
  end

  # Maps each table with a lock in the given mode to whether it was granted.
  def locks_in_mode(connection, mode)
    sql = 'SELECT relation::regclass::text, granted FROM pg_locks WHERE mode = $1 AND relation IS NOT NULL'
    connection.exec_params(sql, [mode]).to_h { |row| [row['relation'], row['granted'] == 't'] }
  end

  def weak_lock_held?(connection)
    weak_locks(connection, granted: true).positive?
  end

  def column_exists?(connection, column, table: 'accounts')
    sql = 'SELECT count(*) FROM information_schema.columns WHERE table_name = $1 AND column_name = $2'
    connection.exec_params(sql, [table, column]).getvalue(0, 0) == '1'
  end

  def autovacuum_running_on_ledger?(connection)
    sql = <<~SQL
      SELECT count(*) FROM pg_stat_activity
       WHERE backend_type = 'autovacuum worker' AND query LIKE 'autovacuum: VACUUM %ledger%'
    SQL
    connection.exec(sql).getvalue(0, 0) == '1'
  end

  def autovacuum_cancellations
    log = ENV.fetch('LOCKWISE_TEST_SERVER_LOG') { raise 'run the specs through bin/test' }
    File.read(log).scan('canceling autovacuum task').size
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  private

  def weak_locks(connection, granted:)
    sql = <<~SQL
      SELECT count(*) FROM pg_locks
       WHERE relation = 'accounts'::regclass AND mode = 'ShareUpdateExclusiveLock' AND granted = $1
    SQL
    connection.exec_params(sql, [granted]).getvalue(0, 0).to_i
  end

  def hold_transaction(statement, before, started, release)
    blocker = connect
    blocker.exec(before) if before
    blocker.exec('BEGIN')
    blocker.exec(statement)
    started.push(blocker.backend_pid)
    release.pop
    blocker.exec('COMMIT')
    blocker.close
  end
end
