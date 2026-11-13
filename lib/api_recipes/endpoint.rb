# frozen_string_literal: true

module ApiRecipes
  # One step of a chain: a node of the tree with its path filled. The
  # subclass generated for the node adds a method per child.
  #
  # Every method of this class is a name an endpoint cannot use as a method:
  # the class has only the public methods below, and inside them the only
  # private methods called are raise and block_given?.
  class Endpoint
    # args: the path values, then optionally a Hash of options for http.rb.
    # overrides: the options given to with, for this request only.
    def initialize(context, definition, parent_path, args, overrides = nil)
      @context = context
      @definition = definition
      @parent_path = parent_path
      @args = args
      @overrides = overrides
      last = args.last
      @options = last.is_a?(Hash) ? last : nil
      params = definition.path_params
      count = @options ? args.size - 1 : args.size
      raise PathParamsMismatch.new(definition.full_path, params, args.first(count)) unless count == params.size

      own = definition.template.expand(args, endpoint: definition.full_name)
      if own.empty?
        @path = parent_path
      else
        path = "#{parent_path}/#{own}"
        path.squeeze!('/')
        @path = path.freeze
      end
    end

    # The child called name. With a block, sends its request at once.
    def [](name, *args, &block)
      endpoint = @context.handles.endpoint(@context, @definition, @path, name, args)
      endpoint.run(&block) if block
      endpoint
    end

    # Sends the request. With a block, passes it the response.
    def run
      response = Request.new(context: @context, definition: @definition, path: @path, options: @options,
                             overrides: @overrides).perform
      yield response if block_given?
      response
    end

    # The URL without the query string, or nil without a route. Sends nothing.
    def url
      Request.new(context: @context, definition: @definition, path: @path, options: @options,
                  overrides: @overrides).url
    end

    # A copy with options for this request only, not for the children. An
    # option given as nil drops the one given before.
    def with(options)
      overrides = Compiler.resolve_options(options, :with_endpoint)
      if @overrides
        merged = @overrides.merge(overrides)
        options.each { |key, value| merged.delete(key.to_sym) if value.nil? }
        overrides = merged.freeze
      end
      self.class.new(@context, @definition, @parent_path, @args, overrides)
    end

    attr_reader :definition

    def inspect
      "#<ApiRecipes::Endpoint #{@definition.full_name} #{@definition.verb.to_s.upcase} " \
        "#{@context.shown_origin}#{@path}>"
    end
  end
end
