# frozen_string_literal: true

module Lockwise
  # Let the lock talk to a pg connection or to an ActiveRecord connection.
  module Adapters
    def self.for(connection)
      if defined?(PG::Connection) && connection.is_a?(PG::Connection)
        Pg.new(connection)
      else
        ActiveRecord.new(connection)
      end
    end

    # A connection from the pg gem.
    class Pg
      def initialize(connection)
        @connection = connection
      end

      def execute(sql) = @connection.exec(sql)
      def select(sql, binds) = @connection.exec_params(sql, binds).to_a
      def quote(table) = @connection.quote_ident(table)
      def idle? = @connection.transaction_status == PG::PQTRANS_IDLE
      def lock_timeout_errors = [PG::LockNotAvailable]

      def transaction
        @connection.exec('BEGIN')
        result = yield
        @connection.exec('COMMIT')
        result
      rescue StandardError
        @connection.exec('ROLLBACK') unless idle?
        raise
      end
    end

    # An ActiveRecord connection, or a proxy in front of one. The transaction
    # goes through ActiveRecord, so that it knows one is open.
    class ActiveRecord
      def initialize(connection)
        @connection = connection
      end

      def execute(sql) = @connection.execute(sql)
      def select(sql, binds) = @connection.exec_query(sql, 'Lockwise', binds).to_a
      def quote(table) = @connection.quote_table_name(table)
      def idle? = !@connection.transaction_open?
      def lock_timeout_errors = [::ActiveRecord::LockWaitTimeout]
      def transaction(&) = @connection.transaction(&)
    end
  end
end
