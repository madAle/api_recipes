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

  # Every operation of a description as [VERB, path], where each {parameter}
  # of the path is replaced by P1, P2... in order.
  def operations_of(document)
    methods = %w[get put post delete options head patch trace]
    document.root.fetch('paths', {}).flat_map do |path, item|
      item = document.resolve(item, 'paths')
      methods.select { |method| item[method].is_a?(Hash) }.map { |method| [method.upcase, with_tokens(path)] }
    end
  end

  # The same pairs for a tree of nodes built by the importer: the tree is
  # configured as an api of the gem, and every endpoint that can be called is
  # called through the DSL with P1, P2... as path values.
  def imported_operations(nodes)
    configure_test_apis(imported: { 'host' => 'h.test', 'endpoints' => nodes_as_config(nodes) })
    routes_as_operations(ApiRecipes.imported)
  end

  def routes_as_operations(api)
    found = []
    walk = lambda do |handle, definition, used|
      definition.endpoints.each_value do |child|
        count = child.path_params.size
        values = (1..count).map { |offset| "P#{used + offset}" }
        endpoint = handle[child.name, *values]
        if child.route?
          path = endpoint.url.path.gsub(/%\h\h/) { |escape| escape[1, 2].hex.chr }.force_encoding(Encoding::UTF_8)
          found << [child.verb.to_s.upcase, path]
        end
        walk.call(endpoint, child, used + count)
      end
    end
    walk.call(api, api.definition, 0)
    found
  end

  def nodes_as_config(nodes)
    nodes.to_h do |node|
      options = node.options.transform_keys(&:to_s)
      options['endpoints'] = nodes_as_config(node.children) unless node.children.empty?
      [node.name, options]
    end
  end

  # A tree of nodes as { name => options }, with :children when there are some.
  def tree_as_hash(nodes)
    nodes.to_h do |node|
      [node.name, node.children.empty? ? node.options : node.options.merge(children: tree_as_hash(node.children))]
    end
  end

  def with_tokens(path)
    index = 0
    path.gsub(/\{[^{}]*\}/) { "P#{index += 1}" }
  end
end
