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

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 2.1.0'

  spec.add_dependency 'oj', '~> 3.3.5'
  spec.add_dependency 'oj_mimic_json', '~> 1.0.1'
  spec.add_dependency 'http', '~> 1.0.0'
end
