require 'yaml'

# Helpers for the specs of `api_recipes import`. They are methods, not
# constants: a constant of the module is not visible from an example.
module ImportHelpers
  # A small valid OpenAPI description as YAML text, with overrides merged over
  # its top-level keys.
  def openapi(overrides = {})
    base = {
      'openapi' => '3.0.3',
      'info' => { 'title' => 'Test API', 'version' => '1.0' },
      'servers' => [{ 'url' => 'https://api.example.test' }],
      'paths' => { '/users' => { 'get' => { 'responses' => { '200' => { 'description' => 'ok' } } } } }
    }
    YAML.dump(base.merge(overrides))
  end

  def fixture_openapi(name)
    File.expand_path("../fixtures/openapi/#{name}", __dir__)
  end
end
