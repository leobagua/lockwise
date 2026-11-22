# frozen_string_literal: true

RSpec.describe Lockwise do
  let(:connection) { connect }

  before { create_accounts_table(connection) }
  after { connection.close }

  it 'waits for an open transaction to end, then runs the block' do
    release, blocker = open_transaction_on_accounts
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
    release, blocker = open_transaction_on_accounts
    releaser = release_after(release, 1.5) # still young when the lock looks, so the first request times out

    ran_at = []
    described_class.with_lock(connection, 'accounts', max_pause: 0.5, poll: 0.05, cooldown: 0.2) do
      ran_at << monotonic_now
      connection.exec('ALTER TABLE accounts ADD COLUMN note text')
    end
    blocker.join

    expect(ran_at.size).to eq(1)
    expect(ran_at.first).to be > releaser.value
    expect(column_exists?(connection, 'note')).to be(true)
  end

  it 'lets reads and writes run while it waits on the weak lock' do
    release, blocker = open_transaction_on_accounts
    sleep 1
    locker = lock_accounts_in_background('ALTER TABLE accounts ADD COLUMN note text', max_pause: 0.5, poll: 0.05)
    sleep 0.05 until weak_lock_held?(connection)

    connection.exec("SET lock_timeout = '200ms'")
    connection.exec('INSERT INTO accounts VALUES (2)')
    expect(connection.exec('SELECT count(*) FROM accounts').getvalue(0, 0)).to eq('2')

    release.push(true)
    [blocker, locker].each(&:join)
    expect(column_exists?(connection, 'note')).to be(true)
  end

  it 'makes two runs on the same table take turns, in order of arrival' do
    release, blocker = open_transaction_on_accounts
    sleep 1
    first = lock_accounts_in_background('ALTER TABLE accounts ADD COLUMN note text', max_pause: 0.5, poll: 0.05)
    sleep 0.05 until weak_lock_held?(connection)
    second = lock_accounts_in_background('ALTER TABLE accounts ADD COLUMN owner text', max_pause: 0.5, poll: 0.05)
    sleep 0.05 until weak_lock_waiting?(connection)

    release.push(true)
    blocker.join

    expect(first.value).to be < second.value
    expect(column_exists?(connection, 'note')).to be(true)
    expect(column_exists?(connection, 'owner')).to be(true)
  end

  it 'gives up after a failed request when there is no time for another one' do
    release, blocker, blocker_pid = open_transaction_on_accounts

    expect { described_class.with_lock(connection, 'accounts', max_pause: 0.5, cooldown: 1, max_runtime: 1) { nil } }
      .to raise_error(Lockwise::GaveUpError) { |error|
        expect(error.reason).to eq('attempt_failed')
        expect(error.blockers.map(&:pid)).to eq([blocker_pid])
      }

    expect(weak_lock_held?(connection)).to be(false)
    release.push(true)
    blocker.join
  end

  it 'gives up and names the long transaction that never ends' do
    release, blocker, blocker_pid = open_transaction_on_accounts
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
    release, blocker, blocker_pid = open_transaction_on_accounts(Database::WEAK_LOCK)

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
