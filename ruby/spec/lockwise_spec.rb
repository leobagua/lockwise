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
end
