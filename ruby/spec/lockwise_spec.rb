# frozen_string_literal: true

RSpec.describe Lockwise do
  let(:connection) { connect }

  before { create_accounts_table(connection) }
  after { connection.close }

  it 'waits for an open transaction to end, then runs the block' do
    release, blocker = open_transaction
    sleep 1 # older than max_pause, so the lock has to wait for it
    releaser = release_after(release, 1)

    ran_at = nil
    described_class.with_lock(connection, 'accounts', max_pause: 0.5, poll: 0.05) do
      ran_at = monotonic_now
      connection.exec('ALTER TABLE accounts ADD COLUMN note text')
    end
    blocker.join

    expect(ran_at).to be > releaser.value
    expect(column_exists?(connection, 'note')).to be(true)
  end

  it 'tries again after a strong lock request that times out' do
    release, blocker = open_transaction
    releaser = release_after(release, 1.5) # still young when the lock looks, so the first request times out

    applied_at = []
    described_class.with_lock(connection, 'accounts', max_pause: 0.5, poll: 0.05, cooldown: 0.2) do
      connection.exec('ALTER TABLE accounts ADD COLUMN note text')
      applied_at << monotonic_now
    end
    blocker.join

    expect(applied_at.size).to eq(1)
    expect(applied_at.first).to be > releaser.value
    expect(column_exists?(connection, 'note')).to be(true)
  end

  it 'lets reads and writes run while it waits on the weak lock' do
    release, blocker = open_transaction
    sleep 1
    locker = lock_in_background('accounts', 'ALTER TABLE accounts ADD COLUMN note text', max_pause: 0.5, poll: 0.05)
    sleep 0.05 until weak_lock_held?(connection)

    connection.exec("SET lock_timeout = '200ms'")
    connection.exec('INSERT INTO accounts VALUES (2)')
    expect(connection.exec('SELECT count(*) FROM accounts').getvalue(0, 0)).to eq('2')

    release.push(true)
    [blocker, locker].each(&:join)
    expect(column_exists?(connection, 'note')).to be(true)
  end

  it 'makes two runs on the same table take turns, in order of arrival' do
    release, blocker = open_transaction
    sleep 1
    first = lock_in_background('accounts', 'ALTER TABLE accounts ADD COLUMN note text', max_pause: 0.5, poll: 0.05)
    sleep 0.05 until weak_lock_held?(connection)
    second = lock_in_background('accounts', 'ALTER TABLE accounts ADD COLUMN owner text', max_pause: 0.5, poll: 0.05)
    sleep 0.05 until weak_lock_waiting?(connection)

    release.push(true)
    blocker.join

    expect(first.value).to be < second.value
    expect(column_exists?(connection, 'note')).to be(true)
    expect(column_exists?(connection, 'owner')).to be(true)
  end

  context 'when a foreign key is added while a reader is open' do
    before do
      connection.exec('DROP TABLE IF EXISTS owners')
      connection.exec('CREATE TABLE owners (id int PRIMARY KEY)')
      connection.exec('ALTER TABLE accounts ADD COLUMN owner_id int')
    end

    def add_foreign_key_at(**options)
      described_class.with_lock(connection, 'accounts', max_pause: 0.5, poll: 0.05, cooldown: 0.2, **options) do
        connection.exec('ALTER TABLE accounts ADD FOREIGN KEY (owner_id) REFERENCES owners (id) NOT VALID')
        monotonic_now
      end
    end

    it 'lets the DDL ask for its own lock, so it does not wait for the reader' do
      release, reader = open_transaction('SELECT * FROM accounts')
      releaser = release_after(release, 1.5)

      applied_at = add_foreign_key_at
      reader.join

      expect(applied_at).to be < releaser.value
    end

    it 'does not wait for the reader with SHARE ROW EXCLUSIVE taken first' do
      release, reader = open_transaction('SELECT * FROM accounts')
      releaser = release_after(release, 1.5)

      applied_at = add_foreign_key_at(share_row_exclusive: true)
      reader.join

      expect(applied_at).to be < releaser.value
    end

    it 'takes ACCESS EXCLUSIVE first when asked to, so it waits for the reader' do
      release, reader = open_transaction('SELECT * FROM accounts')
      releaser = release_after(release, 1.5)

      applied_at = add_foreign_key_at(access_exclusive: true)
      reader.join

      expect(applied_at).to be > releaser.value
    end
  end

  context 'with two tables' do
    before do
      connection.exec('DROP TABLE IF EXISTS owners')
      connection.exec('CREATE TABLE owners (id int PRIMARY KEY)')
      connection.exec('ALTER TABLE accounts ADD COLUMN owner_id int')
    end

    it 'waits for a long transaction on any of the tables' do
      release, reader = open_transaction('SELECT * FROM owners')
      sleep 1
      releaser = release_after(release, 1)

      applied_at = described_class.with_lock(connection, %w[owners accounts], max_pause: 0.5, poll: 0.05) do
        connection.exec('ALTER TABLE accounts ADD FOREIGN KEY (owner_id) REFERENCES owners (id) NOT VALID')
        monotonic_now
      end
      reader.join

      expect(applied_at).to be > releaser.value
    end

    it 'takes ACCESS EXCLUSIVE in the order given' do
      release, blocker = open_transaction
      locker = lock_in_background(%w[owners accounts], 'SELECT 1', access_exclusive: true, max_pause: 5)
      sleep 0.05 until locks_in_mode(connection, 'AccessExclusiveLock').size == 2

      expect(locks_in_mode(connection, 'AccessExclusiveLock')).to eq('owners' => true, 'accounts' => false)
      release.push(true)
      [blocker, locker].each(&:join)
    end

    it 'takes SHARE ROW EXCLUSIVE in the order given' do
      release, blocker = open_transaction
      locker = lock_in_background(%w[owners accounts], 'SELECT 1', share_row_exclusive: true, max_pause: 5)
      sleep 0.05 until locks_in_mode(connection, 'ShareRowExclusiveLock').size == 2

      expect(locks_in_mode(connection, 'ShareRowExclusiveLock')).to eq('owners' => true, 'accounts' => false)
      release.push(true)
      [blocker, locker].each(&:join)
    end

    it 'refuses both explicit locks at once' do
      expect { described_class.with_lock(connection, 'accounts', access_exclusive: true, share_row_exclusive: true) }
        .to raise_error(ArgumentError)
    end
  end

  it 'releases the weak lock from time to time, so other maintenance gets a turn' do
    release, blocker = open_transaction
    sleep 1
    locker = lock_in_background('accounts', 'ALTER TABLE accounts ADD COLUMN note text',
                                max_pause: 0.5, poll: 0.05, cooldown: 0.3, weak_lock_hold: 1)
    sleep 0.05 until weak_lock_held?(connection)

    connection.exec("SET lock_timeout = '3s'")
    expect { connection.exec("BEGIN; #{Database::WEAK_LOCK}; COMMIT") }.not_to raise_error

    release.push(true)
    [blocker, locker].each(&:join)
    expect(column_exists?(connection, 'note')).to be(true)
  end

  it 'gives up after a failed request when there is no time for another one' do
    release, blocker, blocker_pid = open_transaction

    add_note = -> { connection.exec('ALTER TABLE accounts ADD COLUMN note text') }
    expect { described_class.with_lock(connection, 'accounts', max_pause: 0.5, cooldown: 1, max_runtime: 1, &add_note) }
      .to raise_error(Lockwise::GaveUpError) { |error|
        expect(error.reason).to eq('attempt_failed')
        expect(error.blockers.map(&:pid)).to eq([blocker_pid])
      }

    expect(weak_lock_held?(connection)).to be(false)
    release.push(true)
    blocker.join
  end

  it 'gives up and names the long transaction that never ends' do
    release, blocker, blocker_pid = open_transaction
    sleep 1
    block_ran = false

    expect { described_class.with_lock(connection, 'accounts', max_pause: 0.5, max_runtime: 1) { block_ran = true } }
      .to raise_error(Lockwise::GaveUpError) { |error|
        expect(error.reason).to eq('long_blockers')
        expect(error.blockers.map(&:pid)).to eq([blocker_pid])
      }

    expect(block_ran).to be(false)
    expect(weak_lock_held?(connection)).to be(false)
    release.push(true)
    blocker.join
  end

  it 'gives up and names the session that holds the weak lock' do
    release, blocker, blocker_pid = open_transaction(Database::WEAK_LOCK)

    expect { described_class.with_lock(connection, 'accounts', max_runtime: 1) { nil } }
      .to raise_error(Lockwise::GaveUpError) { |error|
        expect(error.reason).to eq('prelock_timeout')
        expect(error.blockers.map(&:pid)).to eq([blocker_pid])
      }

    release.push(true)
    blocker.join
  end

  it 'refuses a connection that is already in a transaction and leaves it open' do
    connection.exec('BEGIN')
    block_ran = false

    expect { described_class.with_lock(connection, 'accounts') { block_ran = true } }
      .to raise_error(Lockwise::TransactionOpenError)

    expect(block_ran).to be(false)
    expect(connection.transaction_status).to eq(PG::PQTRANS_INTRANS)
  end
end
