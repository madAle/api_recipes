# frozen_string_literal: true

module ApiRecipes
  module CLI
    class Upgrade
      # What changed in 3.0 and is found by reading the Ruby of a file as a
      # tree, where a line alone does not tell. Nothing is run.
      module TreeRules
        Found = Data.define(:line, :kind, :message)

        WRITERS = %i[authorization= basic_auth=].freeze
        SENDS = %i[send public_send __send__].freeze
        ADDRESS = %w[host protocol port].freeze
        CREDENTIALS = %w[authorization basic_auth].freeze
        WRITER = 'authorization= and basic_auth= now work on an object only: on ApiRecipes.name, on a class and on a module ' \
                 'they raise. Give the credential to config.values, to `api :name, authorization: ...`, or to with(...) for one request'
        NOT_TEXT = 'a credential must be a String: a Symbol or a number raises InvalidCredential, convert it with to_s'
        RUN_VALUE = 'run with a block now returns the Response, not what the block returns: take the value inside the block, or from the response'
        RESPONSE = {
          request: 'request was removed from the response, because the request holds the credentials: read uri, or original_response',
          to_s: 'to_s on a response now returns the body, as the http.rb response does: it was the default text of the object',
          respond_to?: 'respond_to? on a response now tells the truth: true for the methods the response forwards, false for the others'
        }.freeze

        # What gives an api in a file: the names an api is called by, and
        # the variables that hold one.
        Scope = Data.define(:names, :holders)

        # uses_gem: whether the code names ApiRecipes or calls an api. The
        # rules that also match other code are applied only then, and only
        # to what an api gives.
        # reported: the lines where a rule on lines already found a writer.
        # apis: the names the apis of the project are called by; those that
        # the file declares with `api :name` are added.
        def self.findings(text, uses_gem:, reported: [], apis: [])
          tree = Code.tree(text)
          return [] unless tree

          found = []
          scope = uses_gem ? scope_of(tree, apis) : nil
          responses = uses_gem ? responses_of(tree, scope) : []
          each(tree) do |node, parents|
            constants(node, found) if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
            next unless uses_gem && node.is_a?(Prism::CallNode)

            declaration(node, found)
            writer(node, found, reported, scope)
            block_value(node, parents, found, scope)
            response(node, responses, found)
          end
          found.uniq.sort_by(&:line)
        end

        def self.scope_of(tree, apis)
          names = apis.map(&:to_sym)
          each(tree) do |node, _|
            next unless node.is_a?(Prism::CallNode) && node.name == :api && node.receiver.nil?

            first = node.arguments&.arguments&.first
            names << first.unescaped.to_sym if first.is_a?(Prism::SymbolNode)
            as = keywords(node).to_h['as']
            names << as.unescaped.to_sym if as.is_a?(Prism::SymbolNode)
          end
          scope = Scope.new(names: names.uniq, holders: [])
          each(tree) do |node, _|
            holder = node.is_a?(Prism::LocalVariableWriteNode) || node.is_a?(Prism::InstanceVariableWriteNode)
            scope.holders << node.name if holder && api?(node.value, scope)
          end
          scope
        end

        # Whether node gives an api, or a part of one: ApiRecipes, a call of
        # an api by its name, or a variable that holds one.
        def self.api?(node, scope)
          case node
          when Prism::CallNode
            scope.names.include?(node.name) || (node.receiver ? api?(node.receiver, scope) : false)
          when Prism::ConstantReadNode, Prism::ConstantPathNode then node.slice.delete_prefix('::') == 'ApiRecipes'
          when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then scope.holders.include?(node.name)
          else false
          end
        end

        # Every node of the tree with the nodes that contain it, the nearest last.
        def self.each(node, parents = [], &block)
          return unless node

          block.call(node, parents)
          inside = parents + [node]
          node.compact_child_nodes.each { |child| each(child, inside, &block) }
        end

        def self.at(node) = node.location.start_line

        # The keys of the keywords of a call, when they are written as names.
        def self.keywords(call)
          hash = call.arguments&.arguments&.last
          return [] unless hash.is_a?(Prism::KeywordHashNode)

          hash.elements.filter_map { |pair| pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode) ? [pair.key.unescaped, pair.value] : nil }
        end

        # `api :name`: a name that is already a method, an address of its own
        # without a credential of its own, a credential that is not text.
        def self.declaration(call, found)
          name = call.arguments&.arguments&.first
          return unless call.name == :api && call.receiver.nil? && name.is_a?(Prism::SymbolNode)

          given = keywords(call)
          keys = given.map(&:first)
          if !keys.include?('as') && taken?(name.unescaped)
            found << Found.new(at(call), :breaks, "api :#{shown(name.unescaped)} raises ApiNameClashError, because a class already has a method " \
                                                  "with that name: give another one, as in `api :#{shown(name.unescaped)}, as: :another_name`")
          end
          if (keys & ADDRESS).any? && (keys & CREDENTIALS).empty?
            found << Found.new(at(call), :check, "this class gives the api its own #{(keys & ADDRESS).join(', ')}: the credential of the application is " \
                                                 'not sent to another address, so give the class its own, as in `api :name, host: ..., authorization: ...`')
          end
          given.each { |key, value| found << Found.new(at(value), :breaks, NOT_TEXT) if key == 'authorization' && not_text?(value) }
        end

        def self.shown(name) = name.match?(/\A\w{1,40}[?!]?\z/) ? name : 'name'

        # Whether a class cannot have a method of that name for an api:
        # what Declaration checks, on a class with nothing of its own.
        def self.taken?(name)
          return false unless Internals::Compiler::METHOD_NAME.match?(name)

          probe = Class.new
          Internals::Handles::RESERVED.include?(name.to_sym) || probe.respond_to?(name, true) || probe.method_defined?(name) ||
            probe.private_method_defined?(name)
        end

        def self.not_text?(value) = [Prism::SymbolNode, Prism::IntegerNode, Prism::FloatNode].any? { |kind| value.is_a?(kind) }

        # A credential assigned with a writer: where a rule on lines did not
        # see it (in the body of a class, through a variable, over two
        # lines, with send), and a value that is not text.
        def self.writer(call, found, reported, scope)
          return unless api?(call.receiver, scope)

          if WRITERS.include?(call.name)
            value = call.arguments&.arguments&.first
            found << Found.new(at(call), :breaks, NOT_TEXT) if call.name == :authorization= && value && not_text?(value)
            found << Found.new(at(call), :check, WRITER) unless reported.include?(at(call)) || reported.include?(call.location.end_line)
          elsif SENDS.include?(call.name)
            name = call.arguments&.arguments&.first
            found << Found.new(at(call), :check, WRITER) if name.is_a?(Prism::SymbolNode) && WRITERS.include?(name.unescaped.to_sym)
          end
        end

        # run with a block, where what it returns is assigned, returned,
        # passed on or called.
        def self.block_value(call, parents, found, scope)
          return unless call.name == :run && call.block.is_a?(Prism::BlockNode) && api?(call.receiver, scope)

          parent = parents.last
          used = parent.class.name.end_with?('WriteNode') || parent.is_a?(Prism::ArgumentsNode) ||
                 (parent.is_a?(Prism::CallNode) && parent.receiver.equal?(call))
          found << Found.new(at(call), :check, RUN_VALUE) if used
        end

        # The names of the variables that hold a response: what run returned,
        # and what run passes to its block.
        def self.responses_of(tree, scope)
          names = []
          each(tree) do |node, _|
            if (node.is_a?(Prism::LocalVariableWriteNode) || node.is_a?(Prism::InstanceVariableWriteNode)) && run?(node.value, scope)
              names << node.name
            elsif run?(node, scope) && node.block.is_a?(Prism::BlockNode)
              inner = node.block.parameters
              first = inner.is_a?(Prism::BlockParametersNode) ? inner.parameters&.requireds&.first : nil
              names << first.name if first.respond_to?(:name)
            end
          end
          names.uniq
        end

        def self.run?(node, scope) = node.is_a?(Prism::CallNode) && node.name == :run && api?(node.receiver, scope)

        def self.response(call, responses, found)
          holder = call.receiver
          return unless RESPONSE.key?(call.name) && (holder.is_a?(Prism::LocalVariableReadNode) || holder.is_a?(Prism::InstanceVariableReadNode))
          return unless responses.include?(holder.name)
          # `response.request` is found by the rule on lines.
          return if call.name == :request && holder.name == :response

          found << Found.new(at(call), :check, RESPONSE[call.name])
        end

        # The constants of the gem that a class finds first once it includes
        # ApiRecipes: the errors, Internals and VERSION.
        def self.shadowing
          @shadowing ||= ApiRecipes.constants.select do |name|
            value = ApiRecipes.const_get(name)
            %i[Internals VERSION].include?(name) || (value.is_a?(Class) && value <= ApiRecipes::Error)
          end
        end

        # In the body of a class or a module that includes ApiRecipes, a
        # constant written alone that the gem has too, and that the body
        # does not define.
        def self.constants(owner, found)
          body = owner.body.is_a?(Prism::StatementsNode) ? owner.body.body : []
          includes = body.any? do |node|
            node.is_a?(Prism::CallNode) && node.name == :include && node.receiver.nil? &&
              node.arguments&.arguments&.any? { |one| one.slice.delete_prefix('::') == 'ApiRecipes' }
          end
          return unless includes

          defined = body.filter_map do |node|
            next node.name if node.is_a?(Prism::ConstantWriteNode)

            node.constant_path.slice.to_sym if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          end
          each(owner.body) do |node, parents|
            next unless node.is_a?(Prism::ConstantReadNode) && shadowing.include?(node.name) && !defined.include?(node.name)
            # A class or a module written inside has its own constants.
            next if parents.any? { |one| one.is_a?(Prism::ClassNode) || one.is_a?(Prism::ModuleNode) }
            # In Name::Error only Name is looked for from here. An older
            # Prism gives the last name of a path as a node of its own.
            path = parents.last
            next if path.is_a?(Prism::ConstantPathNode) && !path.parent.equal?(node)

            found << Found.new(at(node), :check, "#{node.name} written alone in a class that includes ApiRecipes is now ApiRecipes::#{node.name}: " \
                                                 "write ::#{node.name} for a constant of the application with that name")
          end
        end
      end

      # What changed in 3.0 and is found in a file that describes apis.
      module ConfigRules
        INHERITED = %w[timeout on_bad_code mime_type verify_with].freeze

        # [message, ...] for the description of one file: { name => options }.
        def self.findings(apis)
          found = []
          apis.each { |name, options| walk(options, [place(name)], found, true) if options.is_a?(Hash) }
          found
        end

        def self.place(name) = name.to_s.gsub(/[^[:print:]]/, '?')[0, 40]

        def self.value(options, key) = options.key?(key) ? options[key] : options[key.to_sym]

        def self.walk(options, path, found, root)
          endpoints = value(options, 'endpoints')
          return unless endpoints.is_a?(Hash)

          endpoints.each do |name, body|
            here = path + ['endpoints', place(name)]
            base = root ? ApiRecipes::Api : ApiRecipes::Endpoint
            if Internals::Compiler::METHOD_NAME.match?(name.to_s) && Internals::Handles.taken?(base, name.to_sym)
              found << "#{here.join('.')}: an endpoint with this name has no method of its own, because #{place(name)} is a method of the " \
                       "object that would have it: reach it with [:#{place(name)}], or give it another name and its `path`"
            end
            next unless body.is_a?(Hash)

            inside = value(body, 'endpoints')
            if inside.is_a?(Hash)
              INHERITED.each do |key|
                next if value(body, key).nil?

                without = inside.select { |_, child| !child.is_a?(Hash) || value(child, key).nil? }.keys.map { |child| place(child) }
                next if without.empty?

                found << "#{here.join('.')}: #{key} is set here, and the endpoints it contains that do not set it now find it here " \
                         "(#{without.first(5).join(', ')}#{', ...' if without.size > 5}): in 2.x they took the one of the api"
              end
            end
            walk(body, here, found, false)
          end
        end
      end
    end
  end
end
