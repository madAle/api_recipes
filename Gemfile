source 'https://rubygems.org'

gemspec

gem 'rake', '~> 13.0'

group :test do
  gem 'rspec', '~> 3.8.0'
  gem 'guard',          '~> 2.15.0'
  gem 'guard-rspec',    '~> 4.7.3'
  gem 'guard-bundler',  '~> 2.2.1'
  # Pick the uri gem to test against, e.g. URI_VERSION='~> 1.0'. Unset, Ruby's
  # default gem is used: 0.x up to Ruby 3.3, 1.x from Ruby 3.4.
  gem 'uri', ENV['URI_VERSION'] unless ENV['URI_VERSION'].to_s.empty?
end
