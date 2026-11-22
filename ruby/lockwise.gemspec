# frozen_string_literal: true

require_relative 'lib/lockwise/version'

Gem::Specification.new do |spec|
  spec.name = 'lockwise'
  spec.version = Lockwise::VERSION
  spec.authors = ['Leonardo da Rosa']
  spec.summary = 'Takes strong locks on hot Postgres tables with one bounded pause.'
  spec.homepage = 'https://gitlab.com/l.rosa/lockwise'
  spec.required_ruby_version = '>= 3.1'
  spec.files = Dir['lib/**/*.rb']
  spec.metadata['rubygems_mfa_required'] = 'true'
end
