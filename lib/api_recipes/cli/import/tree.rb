# frozen_string_literal: true

module ApiRecipes
  module CLI
    class Import
      # The endpoints of a recipe, from the `paths` of a description.
      #
      # A segment without parameters is a name, and each name is a node. The
      # parameters that come before a name travel with that name; those at the
      # end of the path travel with the operation. GET on a path that ends with
      # a name is the node itself; every other operation is a child of the node
      # of the last name, called after its verb.
      class Tree
        Node = Struct.new(:name, :options, :comment, :children)
        Result = Data.define(:nodes, :warnings, :operations, :paths, :skipped)

        METHODS = %w[get put post delete options head patch trace].freeze
        # [name on a path that ends with a name, name on a path that ends with a parameter]
        NAMES = { 'get' => [nil, 'show'], 'post' => %w[create post], 'put' => %w[replace_all replace],
                  'patch' => %w[update_all update], 'delete' => %w[delete_all delete] }.freeze
        PARAMETER = /\{([^{}]*)\}/
        SUCCESS_STATUS = /\A2\d\d\z/

        # A node while the tree is built. key tells apart two nodes of the same
        # parent: it is the text of the description, so two paths that the gem
        # writes in the same way stay two nodes. base is the name before the
        # numbers that keep siblings apart; index finds a child node by its key.
        Entry = Struct.new(:base, :name, :key, :path, :verb, :get, :ok_code, :comment, :operation, :children, :index)

        def self.build(document, only: [], except: [])
          new(document, only, except).build
        end

        def initialize(document, only, except)
          @document = document
          @only = only.map { |glob| pattern(glob) }
          @except = except.map { |glob| pattern(glob) }
          @warnings = []
          @top = entry(nil, nil)
          @operations = 0
          @paths = 0
          @skipped = 0
          @servers = false
        end

        def build
          paths = @document.root['paths']
          paths.each { |path, item| add_path(path, item) } if paths.is_a?(Hash)
          @warnings << 'servers given for a path or an operation are not used: the recipe has one address' if @servers
          name_children(@top, nil)
          Result.new(nodes: nodes_of(@top), warnings: @warnings, operations: @operations, paths: @paths,
                     skipped: @skipped)
        end

        private

        def entry(base, key, **fields)
          Entry.new(base: base, key: key, children: [], index: {}, **fields)
        end

        # ---- reading ----

        def add_path(path, item)
          unless path.is_a?(String) && path.start_with?('/')
            @warnings << "the path #{Import.shown(path)} does not start with /: it was left out"
            return
          end
          # A path that the filters leave out is not read: only counted, when
          # its operations are in the description itself.
          unless selected?(path)
            @skipped += METHODS.count { |method| item[method].is_a?(Hash) } if item.is_a?(Hash)
            return
          end
          item = @document.resolve(item, "paths.#{Import.shown(path)}")
          unless item.is_a?(Hash)
            @warnings << "the path #{Import.shown(path)} is not a mapping: it was left out"
            return
          end
          methods = METHODS.select { |method| item[method].is_a?(Hash) }
          return if methods.empty?

          @paths += 1
          @servers ||= item.key?('servers') || methods.any? { |method| item[method].key?('servers') }
          problem = unwritable(path)
          if problem
            @warnings << "#{Import.shown(path)} (#{methods.size} operation#{'s' unless methods.size == 1}) cannot be " \
                         "written as a path of the gem, because #{problem}: it was left out"
            return
          end
          place(path, path.split('/').reject(&:empty?), item, methods)
        end

        def selected?(path)
          forms = [path, path.delete_prefix('/')]
          return false if @except.any? { |regexp| forms.any? { |form| regexp.match?(form) } }

          @only.empty? || @only.any? { |regexp| forms.any? { |form| regexp.match?(form) } }
        end

        # `*` crosses slashes; every other character stands for itself.
        def pattern(glob)
          Regexp.new("\\A#{Regexp.escape(glob.to_s).gsub('\\*', '.*')}\\z")
        end

        def parameter?(segment) = segment.match?(PARAMETER)

        # Why the gem cannot write a path, or nil. The gem reads `:name` up to
        # the last letter, digit or _; it reads `*name` at the start of a segment
        # as a parameter that spans segments; and it joins two slashes into one.
        def unwritable(path)
          segments = path.split('/', -1).drop(1)
          segments.pop if segments.last == ''
          return 'it has an empty segment' if segments.include?('')
          if segments.any? { |segment| segment.match?(/\{[^{}]*\}\w/) }
            return 'text that starts with a letter, a digit or _ comes right after a parameter'
          end
          return 'a segment starts with * and a name' if segments.any? { |segment| segment.match?(/\A\*[A-Za-z_]/) }

          nil
        end

        def place(path, segments, item, methods)
          slash = path.length > 1 && path.end_with?('/')
          node = @top
          pending = []
          segments.each_with_index do |segment, index|
            if parameter?(segment)
              pending << segment
              next
            end
            closing = slash && index == segments.size - 1
            key = "#{(pending + [segment]).join('/')}#{'/' if closing}"
            node = node.index[key] ||=
              add_child(node, entry(name_of(segment), key, path: written_path(pending + [segment], closing)))
            pending = []
          end
          methods.each { |method| add_operation(node, method, pending, slash, path, item) }
        end

        def add_child(parent, child)
          parent.children << child
          child
        end

        def add_operation(node, method, pending, slash, path, item)
          @operations += 1
          operation = item[method]
          fields = { ok_code: ok_code(operation), comment: comment(method, path, item, operation) }
          if pending.empty? && !node.equal?(@top) && method == 'get'
            node.get = true
            node.ok_code = fields[:ok_code]
            node.comment = fields[:comment]
            return
          end

          name = if pending.empty?
                   node.equal?(@top) && method == 'get' ? 'root' : (NAMES.dig(method, 0) || method)
                 else
                   NAMES.dig(method, 1) || "#{method}_one"
                 end
          add_child(node, entry(name, nil, operation: true, verb: method,
                                           path: pending.empty? ? '' : written_path(pending, slash), **fields))
        end

        # ---- writing paths and names ----

        # "/:owner/:repo/issues" for the segments ['{owner}', '{repo}', 'issues'].
        def written_path(segments, slash)
          used = {}
          text = segments.map do |segment|
            pieces = segment.split(PARAMETER, -1)
            pieces.each_with_index.map do |piece, index|
              index.odd? ? ":#{parameter_name(piece, used)}" : piece.gsub(':', '\\:')
            end.join
          end.join('/')
          "/#{text}#{'/' if slash}"
        end

        # The name of a parameter with letters, digits and _ only, and with a
        # number when the same path already has one with that name.
        def parameter_name(original, used)
          base = original.gsub(/\W/, '_')
          base = "_#{base}" unless base.match?(/\A[A-Za-z_]/)
          name = base
          count = 1
          name = "#{base}_#{count += 1}" while used.key?(name)
          used[name] = true
          name
        end

        def name_of(segment)
          segment.gsub(/([a-z\d])([A-Z])/, '\1_\2').gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                 .downcase.gsub(/[^a-z0-9]/, '_')
        end

        # The nodes born from segments take their names first, then the
        # operations, each in the order of the description.
        def name_children(parent, parent_name)
          taken = {}
          (parent.children.reject(&:operation) + parent.children.select(&:operation)).each do |child|
            child.name = free_name(child.base, taken)
            full = [parent_name, child.name].compact.join('.')
            unless child.name == child.base
              @warnings << "#{parent_name || 'the api'} has two endpoints called #{Import.shown(child.base)}: " \
                           "one is written #{Import.shown(child.name)}"
            end
            warn_unreachable(parent, child, full)
            name_children(child, full)
          end
        end

        def free_name(base, taken)
          name = base
          count = 1
          name = "#{base}_#{count += 1}" while taken.key?(name)
          taken[name] = true
          name
        end

        def warn_unreachable(parent, child, full)
          base = parent.equal?(@top) ? ApiRecipes::Api : ApiRecipes::Endpoint
          method_name = Internals::Compiler::METHOD_NAME.match?(child.name)
          return if method_name && !Internals::Handles.taken?(base, child.name.to_sym)

          reason = method_name ? 'has the name of an existing method' : 'is not the name of a method'
          @warnings << "the endpoint #{Import.shown(full)} #{reason}: reach it with [#{Import.shown(child.name)}]"
        end

        # ---- what an operation says ----

        # The 2xx statuses the operation documents: one, or the list. Nothing
        # when 200 is the only one, since the gem accepts every 2xx by default.
        def ok_code(operation)
          responses = operation['responses']
          return nil unless responses.is_a?(Hash)

          codes = responses.keys.map { |key| Import.text(key).to_s }.grep(SUCCESS_STATUS).map(&:to_i).uniq.sort
          return nil if codes.empty? || codes == [200]

          codes.size == 1 ? codes.first : codes
        end

        def comment(method, path, item, operation)
          details = []
          details << operation['operationId'] if operation['operationId'].is_a?(String)
          details << 'deprecated' if operation['deprecated'] == true
          query = query_parameters(path, item, operation)
          details << "query: #{query.join(', ')}" unless query.empty?
          Import.one_line("#{method.upcase} #{path}#{" (#{details.join('; ')})" unless details.empty?}")
        end

        # The query parameters of the path and of the operation, the second
        # over the first, with a star on the required ones.
        def query_parameters(path, item, operation)
          found = {}
          [item['parameters'], operation['parameters']].each do |list|
            next unless list.is_a?(Array)

            list.each do |parameter|
              parameter = @document.resolve(parameter, "paths.#{Import.shown(path)}.parameters")
              next unless parameter.is_a?(Hash) && parameter['in'] == 'query' && parameter['name'].is_a?(String)

              found[parameter['name']] = parameter['required'] == true
            end
          end
          found.map { |name, required| "#{name}#{'*' if required}" }
        end

        # ---- result ----

        def nodes_of(parent)
          parent.children.map do |child|
            Node.new(child.name, options_of(child), child.comment, nodes_of(child))
          end
        end

        def options_of(child)
          options = {}
          options[:path] = child.path unless child.path == "/#{child.name}"
          options[:verb] = child.verb if child.verb && child.verb != 'get'
          options[:route] = false unless child.operation || child.get
          options[:ok_code] = child.ok_code if child.ok_code
          options
        end
      end
    end
  end
end
