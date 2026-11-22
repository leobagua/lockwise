# frozen_string_literal: true

RSpec.describe Lockwise do
  let(:connection) { connect }

  before { create_accounts_table(connection) }
  after { connection.close }

  it 'waits for an open transaction to end, then runs the block' do
    release, blocker = open_transaction_on_accounts
    sleep 1 # older than max_pause, so the lock has to wait for it
    released_at = nil
    releaser = Thread.new do
      sleep 1
      released_at = monotonic_now
      release.push(true)
    end

    ran_at = nil
    described_class.with_lock(connection, 'accounts', max_pause: 0.5, poll: 0.05) do
      ran_at = monotonic_now
      connection.exec('ALTER TABLE accounts ADD COLUMN note text')
    end
    [releaser, blocker].each(&:join)

    expect(ran_at).to be > released_at
    expect(column_exists?(connection, 'note')).to be(true)
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
