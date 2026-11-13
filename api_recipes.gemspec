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
    'source_code_uri' => 'https://github.com/madAle/api_recipes'
  }

  spec.files         = Dir['README.md', 'MIT-LICENSE', 'lib/**/*.rb']
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 2.7.0'

  # '<= 5.1' let in 5.1.0 only, which requires base64 without declaring it: from
  # Ruby 3.4 base64 is no longer a default gem. 5.x stays API compatible; 6.0 is
  # left out until it is verified.
  spec.add_dependency 'http', '>= 4.4', '< 6'
  spec.add_dependency 'logger'
end
