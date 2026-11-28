# frozen_string_literal: true

require 'pg'
require 'lockwise'
require_relative 'support/database'
require_relative 'support/tables'
require_relative 'support/traffic'

RSpec.configure do |config|
  config.include Database
  config.include Tables
  config.disable_monkey_patching!
end
