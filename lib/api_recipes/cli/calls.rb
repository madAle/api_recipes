# frozen_string_literal: true

module ApiRecipes
  module CLI
    # How each endpoint of an api is called in Ruby, after the name of the
    # api: `.repos.issues(owner, repo).create`. It is what `routes` lists,
    # made from the compiled tree, so that a comment that shows it is true
    # when it is written.
    module Calls
      # What a call is made of: names of endpoints and of the parameters of
      # their paths, as the compiler accepts them. Anything else is not written.
      NAMES = /\A[\w.?!(), ]+\z/

      # { names of the endpoint, from the api down => the call } for every
      # endpoint that can be called.
      def self.of(definition, level = definition.endpoints, names = [], steps = [], found = {})
        level.each_value do |node|
          here = names + [node.name.to_s]
          step = steps + ["#{node.name}#{"(#{node.path_params.join(', ')})" unless node.path_params.empty?}"]
          call = ".#{step.join('.')}"
          found[here] = call if node.route? && call.match?(NAMES)
          of(definition, node.endpoints, here, step, found)
        end
        found
      end
    end
  end
end
