# frozen_string_literal: true

RSpec.describe Lockwise, 'with an autovacuum on the table' do
  let(:connection) { connect }

  before { create_ledger_table_with_a_slow_autovacuum(connection) }
  after { connection.close }

  it 'moves the autovacuum out of the way with the weak lock' do
    sleep 0.1 until autovacuum_running_on_ledger?(connection)
    cancellations_before = autovacuum_cancellations

    described_class.with_lock(connection, 'ledger') do
      connection.exec('ALTER TABLE ledger ADD COLUMN note text')
    end

    expect(autovacuum_cancellations).to eq(cancellations_before + 1)
    expect(column_exists?(connection, 'note', table: 'ledger')).to be(true)
  end
end
