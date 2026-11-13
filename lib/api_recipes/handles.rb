# frozen_string_literal: true

module ApiRecipes
  # The classes of one compiled tree: a subclass of Api for the api and a
  # subclass of Endpoint for every node, each with a public method per child
  # that calls []. They are generated once, when the tree is compiled, and
  # named for error messages: ApiRecipes::Api<svc>,
  # ApiRecipes::Endpoint<svc.users.show>.
  class Handles
    # Names that Api and Endpoint, Ruby or common libraries (pp, psych, json)
    # call on an object without being asked, whether or not they are loaded.
    RESERVED = %i[initialize raise block_given? method_missing respond_to_missing? initialize_copy initialize_dup
                  initialize_clone to_ary to_str to_hash to_proc to_a to_io to_path to_int to_regexp to_sym to_enum
                  coerce marshal_dump marshal_load _dump encode_with init_with to_yaml to_json as_json pretty_print
                  pretty_print_cycle pretty_print_inspect pretty_print_instance_variables].freeze

    # Whether a method called name may not be generated on base: a reserved
    # name, a public method, or a private method that does not come from
    # Kernel (BasicObject's hooks, such as singleton_method_added, among
    # them). Kernel's other private methods (test, open, format...) are free.
    def self.taken?(base, name)
      return true if RESERVED.include?(name) || base.public_method_defined?(name)

      base.private_method_defined?(name) && base.instance_method(name).owner != Kernel
    end

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
      klass.set_temporary_name("#{base.name}<#{label}>")
      node.endpoints.each_key do |name|
        if Handles.taken?(base, name)
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
