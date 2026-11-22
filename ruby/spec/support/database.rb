# frozen_string_literal: true

# Helpers that talk to the throwaway Postgres started by bin/test.
module Database
  def connect
    PG.connect(ENV.fetch('LOCKWISE_TEST_CONN') { raise 'run the specs through bin/test' })
  end

  def create_accounts_table(connection)
    connection.exec('SET client_min_messages = warning')
    connection.exec('DROP TABLE IF EXISTS accounts')
    connection.exec('CREATE TABLE accounts (id int PRIMARY KEY) WITH (autovacuum_enabled = false)')
    connection.exec('INSERT INTO accounts VALUES (1)')
  end

  ROW_LOCK = 'UPDATE accounts SET id = id WHERE id = 1'
  WEAK_LOCK = 'LOCK TABLE accounts IN SHARE UPDATE EXCLUSIVE MODE'

  # Opens a transaction that runs the given statement and stays open until
  # something is pushed to the returned queue. Also returns its backend pid.
  def open_transaction_on_accounts(statement = ROW_LOCK)
    release = Queue.new
    started = Queue.new
    thread = Thread.new { hold_transaction(statement, started, release) }
    [release, thread, started.pop]
  end

  def weak_lock_held?(connection)
    sql = "SELECT count(*) FROM pg_locks WHERE relation = 'accounts'::regclass AND mode = 'ShareUpdateExclusiveLock'"
    connection.exec(sql).getvalue(0, 0) != '0'
  end

  def column_exists?(connection, column)
    sql = "SELECT count(*) FROM information_schema.columns WHERE table_name = 'accounts' AND column_name = $1"
    connection.exec_params(sql, [column]).getvalue(0, 0) == '1'
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  private

  def hold_transaction(statement, started, release)
    blocker = connect
    blocker.exec('BEGIN')
    blocker.exec(statement)
    started.push(blocker.backend_pid)
    release.pop
    blocker.exec('COMMIT')
    blocker.close
  end
end
