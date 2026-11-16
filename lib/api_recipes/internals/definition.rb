# frozen_string_literal: true

require 'json'

module ApiRecipes
  module Internals
    # The immutable result of compiling a configuration: one node per api and one
    # per endpoint. Nodes are built by ApiRecipes::Internals::Compiler, never by hand.
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

      # The name of a header as http.rb compares it: without case, and with
      # _ read as -.
      def self.header_key(name) = name.to_s.downcase.tr('_', '-')

      # added over the headers of base that have the same name. One of the
      # two is returned as it is when the other is empty.
      def self.over_headers(base, added)
        return base if added.empty?
        return added if base.empty?

        names = added.each_key.to_h { |name| [header_key(name), true] }
        base.reject { |name, _| names.key?(header_key(name)) }.merge(added).freeze
      end

      # A definition holds the values of default_headers and default_params.
      # Marshal and YAML would write them, so they are refused; JSON gets to_h,
      # which hides them.
      module Serialization
        def marshal_dump = raise(TypeError, "an #{self.class} cannot be serialized: use to_h")

        def encode_with(_coder) = raise(TypeError, "an #{self.class} cannot be serialized: use to_h")

        def as_json(*) = to_h

        def to_json(*args) = to_h.to_json(*args)
      end

      class Api
        include Serialization

        attr_reader :name, :protocol, :host, :port, :base_url, :timeout, :on_bad_code, :mime_type,
                    :verify_with, :default_headers, :default_params, :auth, :variables, :recipe, :endpoints,
                    :host_template, :base_url_template, :header_templates, :param_templates

        def initialize(name:, protocol:, host:, port:, base_url:, timeout:, on_bad_code:, mime_type:, verify_with:,
                       default_headers:, default_params:, auth:, variables:, recipe:, host_template:,
                       base_url_template:, header_templates:, param_templates:, children:)
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
          @default_params = default_params
          @auth = auth
          @variables = variables
          @recipe = recipe
          @host_template = host_template
          @base_url_template = base_url_template
          @header_templates = header_templates
          @param_templates = param_templates
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
            default_headers: default_headers.transform_values { '[FILTERED]' },
            default_params: default_params.transform_values { '[FILTERED]' }, auth: Definition.plain(auth),
            variables: Definition.plain(variables), recipe: Definition.plain(recipe),
            endpoints: endpoints.transform_values(&:to_h)
          }
        end

        # Never shows the values of headers and parameters, or the tree below.
        def inspect
          list = endpoints.empty? ? '' : " endpoints: #{endpoints.keys.join(', ')}"
          "#<#{self.class} #{name} #{protocol}://#{host}#{port && ":#{port}"}#{list}>"
        end

        def pretty_print(printer)
          printer.text(inspect)
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
        include Serialization

        NONE = {}.freeze
        # The options an endpoint that does not set them looks for up the
        # tree: in the endpoints that contain it, from the nearest, then in the
        # api; the first value found is used. default_headers and
        # default_params are looked for in the same way, one name at a time.
        # path, verb, route, ok_code and resource are read only on their endpoint.
        INHERITED = %i[timeout on_bad_code mime_type verify_with].freeze

        # header_templates, param_templates: the headers and the parameters
        # written on this endpoint and on the endpoints above it, the nearest
        # winning, ready to be filled; those of the api are not among them. An
        # endpoint that adds none shares the Hash of the endpoint above it.
        attr_reader :name, :full_name, :path, :full_path, :path_params, :path_variables, :verb, :ok_code, :timeout,
                    :on_bad_code, :mime_type, :verify_with, :header_templates, :param_templates, :parent,
                    :endpoints, :template

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
          @path_variables = template.variable_names
          @verb = own[:verb] || :get
          @route = own[:route].nil? ? true : own[:route]
          @ok_code = own[:ok_code]
          above = parent.is_a?(Endpoint) ? parent : nil
          # The result of the search, kept on each endpoint: the parent has
          # already made its own, so a request does not walk the tree again.
          @taken = INHERITED.to_h { |key| [key, own[key].nil? && above ? above.own(key) : own[key]] }.freeze
          @timeout = @taken[:timeout].nil? ? api.timeout : @taken[:timeout]
          @on_bad_code = @taken[:on_bad_code] || api.on_bad_code
          @mime_type = @taken[:mime_type].nil? ? api.mime_type : @taken[:mime_type]
          @verify_with = @taken[:verify_with] || api.verify_with
          @header_templates = Definition.over_headers(above ? above.header_templates : NONE,
                                                      templates(own[:default_headers], :header))
          params = templates(own[:default_params], :param)
          taken = above ? above.param_templates : NONE
          @param_templates = params.empty? ? taken : taken.merge(params).freeze
          @endpoints = children.call(self).freeze
          freeze
        end

        def route?
          @route
        end

        # The headers and the parameters of header_templates and
        # param_templates as they are written. They are built when asked: a
        # copy kept on every endpoint would cost as much as the tree is deep.
        def default_headers = @header_templates.transform_values(&:to_s).freeze

        def default_params = @param_templates.transform_values(&:to_s).freeze

        # The value written on this endpoint, or nil. For the options of
        # INHERITED, the first value found from this endpoint up to the one
        # under the api: the api is not looked at.
        def own(key) = @taken.key?(key) ? @taken[key] : @own[key]

        def inspect
          "#<#{self.class} #{full_name} #{verb.to_s.upcase} #{full_path}>"
        end

        def pretty_print(printer)
          printer.text(inspect)
        end

        def to_h
          {
            name: name, full_name: full_name, path: path, full_path: full_path,
            path_params: path_params.dup, path_variables: path_variables.dup, verb: verb, route: route?,
            ok_code: Definition.plain(ok_code),
            timeout: timeout, on_bad_code: on_bad_code, mime_type: mime_type, verify_with: verify_with,
            default_headers: @header_templates.transform_values { '[FILTERED]' },
            default_params: @param_templates.transform_values { '[FILTERED]' },
            endpoints: endpoints.transform_values(&:to_h)
          }
        end

        private

        def templates(texts, position)
          return NONE if texts.nil? || texts.empty?

          texts.transform_values { |text| Template.new(text, position) }.freeze
        end

        def join_path(parent_path, own_path)
          joined = own_path.empty? ? parent_path : "#{parent_path}/#{own_path}"
          joined.gsub(%r{/+}, '/').freeze
        end
      end
    end
  end
end
