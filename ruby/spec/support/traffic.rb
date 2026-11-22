# frozen_string_literal: true

# Runs read-and-write transactions on accounts from several threads, one
# thread per think time, each on its own row.
class Traffic
  Sample = Struct.new(:finished_at, :excess)

  def initialize(connect, think_times)
    @connect = connect
    @think_times = think_times
    @samples = Queue.new
    @errors = Queue.new
  end

  def start
    @threads = @think_times.each_with_index.map { |think, index| Thread.new { work(index + 2, think) } }
  end

  def stop
    @stopping = true
    @threads.each(&:join)
  end

  def samples
    Array.new(@samples.size) { @samples.pop }
  end

  def errors
    Array.new(@errors.size) { @errors.pop }
  end

  private

  def work(row, think)
    connection = @connect.call
    transact(connection, row, think.call) until @stopping
  rescue PG::Error => e
    @errors << e
  ensure
    connection&.close
  end

  # The excess is the time the transaction took beyond its own think time.
  def transact(connection, row, pause)
    started_at = now
    connection.exec('BEGIN')
    connection.exec_params('SELECT balance FROM accounts WHERE id = $1', [row])
    sleep pause
    connection.exec_params('UPDATE accounts SET balance = balance + 1 WHERE id = $1', [row])
    connection.exec('COMMIT')
    @samples << Sample.new(now, now - started_at - pause)
  end

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
