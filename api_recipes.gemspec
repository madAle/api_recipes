# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'api_recipes/version'

Gem::Specification.new do |spec|
  spec.name          = 'api_recipes'
  spec.version       = ApiRecipes::VERSION
  spec.authors       = ['Alessandro Verlato']
  spec.email         = ['averlato@gmail.com']

  spec.summary       = %q{Consume HTTP APIs with style}
  spec.homepage      = 'https://github.com/madAle/api_recipes'
  spec.license       = 'MIT'
  spec.metadata      = {
    'changelog_uri'   => 'https://github.com/madAle/api_recipes/blob/master/CHANGELOG.md',
    'source_code_uri' => 'https://github.com/madAle/api_recipes',
    'rubygems_mfa_required' => 'true'
  }

  spec.files         = Dir['README.md', 'MIT-LICENSE', 'UPGRADING.md', 'exe/*', 'lib/**/*.rb']
  spec.bindir        = 'exe'
  spec.executables   = ['api_recipes']
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 3.3.0'

  # The redirect protection needs the on_redirect option of HTTP::Redirector
  # (from 5.1.1). 5.2.0 is the first version that declares base64, which http.rb
  # requires and which is no longer a default gem from Ruby 3.4. 6.0 is left out
  # until it is verified.
  spec.add_dependency 'http', '>= 5.2.0', '< 6'
  spec.add_dependency 'logger'
end
