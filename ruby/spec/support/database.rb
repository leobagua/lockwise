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

  # Holds a row lock on accounts until something is pushed to the returned queue.
  def open_transaction_on_accounts
    release = Queue.new
    locked = Queue.new
    thread = Thread.new { hold_row_lock(locked, release) }
    locked.pop
    [release, thread]
  end

  def column_exists?(connection, column)
    sql = "SELECT count(*) FROM information_schema.columns WHERE table_name = 'accounts' AND column_name = $1"
    connection.exec_params(sql, [column]).getvalue(0, 0) == '1'
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  private

  def hold_row_lock(locked, release)
    blocker = connect
    blocker.exec('BEGIN')
    blocker.exec('UPDATE accounts SET id = id WHERE id = 1')
    locked.push(true)
    release.pop
    blocker.exec('COMMIT')
    blocker.close
  end
end
