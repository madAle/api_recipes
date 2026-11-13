module ApiRecipes
  # The immutable result of compiling a configuration: one node per api and one
  # per endpoint. Nodes are built by ApiRecipes::Compiler, never by hand.
  module Definition
    Route = Struct.new(:call, :verb, :url)

    # Copies Hashes and Arrays so that the caller gets plain, mutable data.
    def self.plain(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), out| out[key] = plain(item) }
      when Array then value.map { |item| plain(item) }
      else value
      end
    end

    class Api
      attr_reader :name, :protocol, :host, :port, :base_url, :timeout, :on_bad_code, :mime_type,
                  :verify_with, :default_headers, :auth, :variables, :recipe, :endpoints,
                  :host_template, :base_url_template, :header_templates

      def initialize(name:, protocol:, host:, port:, base_url:, timeout:, on_bad_code:, mime_type:, verify_with:,
                     default_headers:, auth:, variables:, recipe:, host_template:, base_url_template:,
                     header_templates:, children:)
        @name = name
        @protocol = protocol
        @host = host
        @port = port
        @base_url = base_url
        @timeout = timeout
        @on_bad_code = on_bad_code
        @mime_type = mime_type
        @verify_with = verify_with
        @default_headers = default_headers
        @auth = auth
        @variables = variables
        @recipe = recipe
        @host_template = host_template
        @base_url_template = base_url_template
        @header_templates = header_templates
        @endpoints = children.call(self).freeze
        freeze
      end

      # One entry for every endpoint that can be called, parents first.
      def routes
        origin = "#{protocol}://#{host}#{port && ":#{port}"}"
        nodes.select(&:route?).map do |node|
          Route.new(call_of(node), node.verb, "#{origin}#{node.full_path}")
        end
      end

      def to_h
        {
          name: name, protocol: protocol, host: host, port: port, base_url: base_url, timeout: timeout,
          on_bad_code: on_bad_code, mime_type: mime_type, verify_with: verify_with,
          default_headers: Definition.plain(default_headers), auth: Definition.plain(auth),
          variables: Definition.plain(variables), recipe: Definition.plain(recipe),
          endpoints: endpoints.transform_values(&:to_h)
        }
      end

      private

      def nodes(level = endpoints, found = [])
        level.each_value do |node|
          found << node
          nodes(node.endpoints, found)
        end
        found
      end

      def call_of(node)
        steps = []
        while node.is_a?(Endpoint)
          steps.unshift("#{node.name}#{"(#{node.path_params.join(', ')})" unless node.path_params.empty?}")
          node = node.parent
        end
        "#{name}.#{steps.join('.')}"
      end
    end

    class Endpoint
      attr_reader :name, :full_name, :path, :full_path, :path_params, :verb, :ok_code, :timeout, :on_bad_code,
                  :mime_type, :verify_with, :parent, :endpoints, :template

      def initialize(name:, parent:, own:, template:, children:)
        @name = name
        @parent = parent
        @own = own.freeze
        @template = template
        api = parent
        api = api.parent while api.is_a?(Endpoint)
        parent_path = parent.is_a?(Api) ? "/#{parent.base_url}/" : parent.full_path
        @full_name = "#{parent.is_a?(Api) ? parent.name : parent.full_name}.#{name}".freeze
        @path = (own[:path] || name.to_s).dup.freeze
        @full_path = join_path(parent_path, template.to_s)
        @path_params = template.param_names
        @verb = own[:verb] || :get
        @route = own[:route].nil? ? true : own[:route]
        @ok_code = own[:ok_code]
        @timeout = own[:timeout].nil? ? api.timeout : own[:timeout]
        @on_bad_code = own[:on_bad_code] || api.on_bad_code
        @mime_type = own[:mime_type].nil? ? api.mime_type : own[:mime_type]
        @verify_with = own(:verify_with) || api.verify_with
        @endpoints = children.call(self).freeze
        freeze
      end

      def route?
        @route
      end

      # The value written on this endpoint, or nil. For :verify_with, the
      # value of the nearest endpoint, this one included, that has one.
      def own(key)
        value = @own[key]
        return value unless value.nil? && key == :verify_with && parent.is_a?(Endpoint)

        parent.own(key)
      end

      def to_h
        {
          name: name, full_name: full_name, path: path, full_path: full_path,
          path_params: path_params.dup, verb: verb, route: route?, ok_code: Definition.plain(ok_code),
          timeout: timeout, on_bad_code: on_bad_code, mime_type: mime_type, verify_with: verify_with,
          endpoints: endpoints.transform_values(&:to_h)
        }
      end

      private

      def join_path(parent_path, own_path)
        joined = own_path.empty? ? parent_path : "#{parent_path}/#{own_path}"
        joined.gsub(%r{/+}, '/').freeze
      end
    end
  end
end
