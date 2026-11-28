# frozen_string_literal: true

module Lockwise
  # The tables of one run. Postgres reads each name as SQL does and gives back
  # the form to use in a statement, already quoted, with the schema when it is
  # needed.
  class Tables
    RESOLVE = <<~SQL
      SELECT given.name::regclass::text AS statement_name, given.name::regclass::oid AS oid
        FROM unnest($1::text[]) WITH ORDINALITY AS given(name, position)
       ORDER BY given.position
    SQL

    attr_reader :names

    def initialize(connection, names)
      @connection = connection
      @names = Array(names).map(&:to_s)
    end

    def in_list_order
      resolved.map { |row| row['statement_name'] }
    end

    # Two runs that share tables take the weak locks in the same order, so
    # that they queue instead of deadlocking.
    def in_a_stable_order
      resolved.sort_by { |row| row['oid'].to_i }.map { |row| row['statement_name'] }
    end

    private

    def resolved
      @resolved ||= @connection.select(RESOLVE, [@names])
    end
  end
end
