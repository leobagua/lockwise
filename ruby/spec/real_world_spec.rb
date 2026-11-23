# frozen_string_literal: true

RSpec.describe Lockwise, 'under traffic' do
  let(:connection) { connect }
  let(:fast_worker) { -> { rand(0.005..0.03) } }
  let(:slow_worker) { -> { 0.5 } }
  let(:traffic) { Traffic.new(method(:connect), ([fast_worker] * 6) + [slow_worker]) }

  before do
    create_accounts_table(connection)
    connection.exec('ALTER TABLE accounts ADD COLUMN balance int NOT NULL DEFAULT 0')
    connection.exec('INSERT INTO accounts SELECT generate_series(2, 8)')
  end

  after { connection.close }

  it 'runs the DDL with one short pause while traffic and a long job use the table' do
    traffic.start
    release, long_job = open_transaction
    sleep 1.2 # the long job is now older than max_pause
    releaser = release_after(release, 1.5)

    started_at = monotonic_now
    described_class.with_lock(connection, 'accounts', max_pause: 1.0, poll: 0.05, cooldown: 0.5, max_runtime: 10) do
      connection.exec('ALTER TABLE accounts ADD COLUMN note text')
    end
    sleep 0.5
    traffic.stop
    long_job.join

    samples = traffic.samples
    finished_during_the_wait = samples.count { |sample| sample.finished_at.between?(started_at, releaser.value) }
    expect(traffic.errors).to be_empty
    expect(finished_during_the_wait).to be > 20
    expect(samples.map(&:excess).max).to be < 1.5
    expect(column_exists?(connection, 'note')).to be(true)
  end
end
