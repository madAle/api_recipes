source 'https://rubygems.org'

gemspec

gem 'rake', '~> 13.0'

group :test do
  gem 'rspec',     '~> 3.13'
  gem 'webmock',   '~> 3.34'
  gem 'simplecov', '~> 0.22', require: false
  # Pick the uri gem to test against, e.g. URI_VERSION='~> 1.0'. Unset, Ruby's
  # default gem is used: 0.x up to Ruby 3.3, 1.x from Ruby 3.4.
  gem 'uri', ENV['URI_VERSION'] unless ENV['URI_VERSION'].to_s.empty?
end
