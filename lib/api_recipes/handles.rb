# frozen_string_literal: true

module ApiRecipes
  # The classes of one compiled tree: a subclass of Api for the api and a
  # subclass of Endpoint for every node, each with a public method per child
  # that calls []. They are generated once, when the tree is compiled, and
  # left anonymous.
  class Handles
    # Private methods that Api and Endpoint, or Ruby itself, call on them.
    RESERVED = %i[initialize raise block_given? method_missing respond_to_missing? initialize_copy initialize_dup
                  initialize_clone].freeze

    # One message for every child that has no method of its own.
    attr_reader :warnings

    def initialize(api_definition)
      @name = api_definition.name
      @classes = {}.compare_by_identity
      @warnings = []
      generate(api_definition, Api, api_definition.name)
      @classes.freeze
      @warnings.freeze
      freeze
    end

    def for(definition) = @classes.fetch(definition)

    # The child called name of the node parent, built from the path of the
    # parent and the arguments given to the child.
    def endpoint(context, parent, parent_path, name, args)
      endpoints = parent.endpoints
      child = endpoints[name]
      child ||= endpoints[name.to_sym] if name.is_a?(String) && name.valid_encoding?
      unless child
        owner = parent.is_a?(Definition::Endpoint) ? parent.full_name : parent.name
        raise UnknownEndpoint.new(owner, name, endpoints.keys)
      end
      @classes.fetch(child).new(context, child, parent_path, args)
    end

    def inspect = "#<#{self.class.name} #{@name}>"

    def to_s = inspect

    def pretty_print(queue) = queue.text(inspect)

    private

    def generate(node, base, label)
      klass = Class.new(base)
      node.endpoints.each_key do |name|
        if base.public_method_defined?(name) || RESERVED.include?(name)
          @warnings << "#{label}: endpoint '#{name}' has the name of an existing method; reach it with [#{name.inspect}]"
        else
          klass.define_method(name) { |*args, &block| self[name, *args, &block] }
        end
      end
      @classes[node] = klass
      node.endpoints.each_value { |child| generate(child, Endpoint, child.full_name) }
    end
  end
end
