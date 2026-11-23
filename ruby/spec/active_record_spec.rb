# frozen_string_literal: true

require 'active_record'

RSpec.describe Lockwise, 'with an ActiveRecord connection' do
  let(:connection) { connect }
  let(:migration) do
    Class.new(ActiveRecord::Migration[7.2]) do
      disable_ddl_transaction!

      def up
        Lockwise.with_lock(connection, 'accounts', max_pause: 0.5, poll: 0.05, cooldown: 0.2, max_runtime: 5) do
          add_column :accounts, :note, :text
        end
      end
    end
  end

  before do
    settings = ENV.fetch('LOCKWISE_TEST_CONN').split.to_h { |pair| pair.split('=') }
    ActiveRecord::Base.establish_connection(
      adapter: 'postgresql', host: settings['host'], username: settings['user'], database: settings['dbname']
    )
    ActiveRecord::Migration.verbose = false
    create_accounts_table(connection)
  end

  after do
    ActiveRecord::Base.connection_handler.clear_all_connections!
    connection.close
  end

  it 'runs a migration after the long transaction ends' do
    release, blocker = open_transaction
    sleep 1
    releaser = release_after(release, 1)

    migration.new.migrate(:up)
    finished_at = monotonic_now
    blocker.join

    expect(finished_at).to be > releaser.value
    expect(column_exists?(connection, 'note')).to be(true)
  end

  it 'runs the migration again after a lock request that times out' do
    release, blocker = open_transaction
    releaser = release_after(release, 1.5)

    migration.new.migrate(:up)
    finished_at = monotonic_now
    blocker.join

    expect(finished_at).to be > releaser.value
    expect(column_exists?(connection, 'note')).to be(true)
  end

  it 'gives up and names the long transaction that never ends' do
    release, blocker, blocker_pid = open_transaction
    sleep 1

    expect { migration.new.migrate(:up) }.to raise_error(Lockwise::GaveUpError) { |error|
      expect(error.reason).to eq('long_blockers')
      expect(error.blockers.map(&:pid)).to eq([blocker_pid])
    }
    release.push(true)
    blocker.join
  end

  it 'refuses a connection that ActiveRecord has in a transaction' do
    ActiveRecord::Base.transaction do
      expect { described_class.with_lock(ActiveRecord::Base.lease_connection, 'accounts') { nil } }
        .to raise_error(Lockwise::TransactionOpenError)
    end
  end
end
