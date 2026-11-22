# frozen_string_literal: true

require 'pg'
require 'lockwise'
require_relative 'support/database'

RSpec.configure do |config|
  config.include Database
  config.disable_monkey_patching!
end
