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

  # One major of http.rb: the request, redirect and response code it provides is
  # what the credential protection is verified against. 6.0.4 carries a
  # security fix (GHSA-r98x-p6m8-xcrv).
  spec.add_dependency 'http', '>= 6.0.4', '< 7'
  spec.add_dependency 'logger'
end
