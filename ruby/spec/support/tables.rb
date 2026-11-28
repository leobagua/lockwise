# frozen_string_literal: true

# Creates the tables the specs work on.
module Tables
  def create_accounts_table(connection)
    connection.exec('SET client_min_messages = warning')
    connection.exec('DROP TABLE IF EXISTS accounts')
    connection.exec('CREATE TABLE accounts (id int PRIMARY KEY) WITH (autovacuum_enabled = false)')
    connection.exec('INSERT INTO accounts VALUES (1)')
  end

  def create_events_table_with_two_partitions(connection)
    connection.exec('SET client_min_messages = warning')
    connection.exec('DROP TABLE IF EXISTS events')
    connection.exec('CREATE TABLE events (id int, kind int) PARTITION BY LIST (kind)')
    [1, 2].each do |kind|
      connection.exec("CREATE TABLE events_#{kind} PARTITION OF events FOR VALUES IN (#{kind})
                         WITH (autovacuum_enabled = false)")
    end
    connection.exec('INSERT INTO events VALUES (1, 1), (2, 2)')
  end

  # The cost settings make the autovacuum slow enough to still be running
  # when the lock starts.
  def create_ledger_table_with_a_slow_autovacuum(connection)
    connection.exec('SET client_min_messages = warning')
    connection.exec('DROP TABLE IF EXISTS ledger')
    connection.exec(<<~SQL)
      CREATE TABLE ledger (id int, pad text) WITH (
        autovacuum_vacuum_threshold = 0, autovacuum_vacuum_scale_factor = 0,
        autovacuum_vacuum_insert_threshold = -1, autovacuum_analyze_threshold = 2000000000,
        autovacuum_vacuum_cost_delay = 100, autovacuum_vacuum_cost_limit = 1)
    SQL
    connection.exec("INSERT INTO ledger SELECT number, repeat('x', 200) FROM generate_series(1, 50000) AS number")
    connection.exec('DELETE FROM ledger WHERE id % 2 = 0')
  end
end
