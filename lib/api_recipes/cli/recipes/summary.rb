# frozen_string_literal: true

module ApiRecipes
  module CLI
    class Recipes
      # What a recipe does, in the lines shown before it is installed: where
      # the requests go, where the credential goes, what is sent with every
      # request, which calls change something. Every text that comes from the
      # recipe goes through shown.
      class Summary
        LABEL_WIDTH = 15

        # value as it can be printed: one line, without control and format
        # characters, with one space where it has several, at most limit
        # characters.
        def self.shown(value, limit = 200)
          Internals::PlainYaml.label(value.to_s.scrub('?').gsub(/\p{Z}+/, ' '), limit)
        end

        # origin: where the recipe comes from, in words that are already safe.
        def initialize(recipe, origin: nil)
          @recipe = recipe
          @api = recipe.definition
          @origin = origin
        end

        def title = "#{@recipe.name} #{@recipe.version}"

        def text = @recipe.text

        def lines
          meta = @api.recipe
          rows = [['summary', meta[:summary]], ['homepage', meta[:homepage]], ['from', @origin], ['address', address]]
          rows << ['with defaults', filled_address] unless filled_address == address
          rows << ['credential', credential]
          [title] + rows.reject { |_, text| text.nil? }.flat_map { |label, text| rows_for(label, [text]) } +
            rows_for('headers', headers) + rows_for('params', params) + rows_for('variables', variables) + calls
        end

        # What whoever installs the recipe should know before using it.
        def warnings
          found = []
          auth = @api.auth || {}
          if auth[:type] == :query
            found << "the credential travels in the address, as the query parameter #{shown(auth[:name])}: " \
                     'addresses are written in logs and kept by proxies'
          end
          found << 'the protocol is http: a credential you assign travels without encryption' if @api.protocol == 'http'
          found
        end

        # The address as the recipe writes it, with its {variables}.
        def address(fill = false)
          host = fill ? filled(@api.host) : @api.host
          base = @api.base_url.to_s
          base = filled(base) if fill
          path = "/#{base}".gsub(%r{/+}, '/').chomp('/')
          "#{@api.protocol}://#{host}#{":#{@api.port}" if @api.port}#{path}"
        end

        # The same address with the default of each variable that has one.
        def filled_address = address(true)

        # Where a credential that the application assigns goes. A recipe that
        # declares none does not stop it.
        def credential
          auth = @api.auth || {}
          case auth[:type]
          when :none then 'none declared: a credential you assign still goes in the Authorization header'
          when :header then "in the header #{auth[:name]}"
          when :query then "in the query string, as the parameter #{auth[:name]}"
          else 'in the Authorization header'
          end
        end

        # The headers sent with every request, as "Name: value", then those
        # that an endpoint adds, with the endpoint.
        def headers = sent_always(@api.default_headers, :default_headers)

        # The query parameters sent with every request, in the same form.
        def params = sent_always(@api.default_params, :default_params)

        # Each call that is not a GET, as [verb, call, path].
        def changing_calls
          origin = "#{@api.protocol}://#{@api.host}#{":#{@api.port}" if @api.port}"
          @api.routes.reject { |route| route.verb == :get }.map do |route|
            [route.verb.to_s.upcase, route.call, route.url.delete_prefix(origin)]
          end
        end

        # Each call as { call => verb }.
        def verbs = @api.routes.to_h { |route| [route.call, route.verb.to_s.upcase] }

        # What this recipe changes in the recipe installed now, whose summary
        # is previous (nil when it is not a valid recipe): the address, the
        # credential, the headers, the parameters and the verbs.
        def changes_from(previous)
          return ['  it replaces a file that is not a valid recipe'] if previous.nil?

          found = [%w[address address], ['with defaults', 'filled_address'], %w[credential credential],
                   %w[headers headers], %w[params params]].filter_map do |label, reader|
            before = previous.public_send(reader)
            after = public_send(reader)
            "    #{label}: #{changed(before)} -> #{changed(after)}" unless before == after
          end
          found.concat(verb_changes(previous.verbs))
          found << '    no change in the address, the credential, the headers, the parameters or the verbs' if found.empty?
          ["  changes from #{shown(previous.title, 100)}:"] + found
        end

        private

        def shown(value, limit = 200) = self.class.shown(value, limit)

        # of_api: the headers or the parameters of the api. key: the option
        # that gives them to an endpoint, for itself and for those below it.
        def sent_always(of_api, key)
          found = of_api.map { |name, value| "#{name}: #{shown(value, 100)}" }
          each_endpoint do |node|
            where = "#{shown(node.full_name, 100)}#{' and below' unless node.endpoints.empty?}"
            (node.own(key) || {}).each { |name, value| found << "#{shown(name, 100)}: #{shown(value, 100)} (#{where})" }
          end
          found
        end

        def each_endpoint(level = @api.endpoints, &block)
          level.each_value do |node|
            block.call(node)
            each_endpoint(node.endpoints, &block)
          end
        end

        def changed(value)
          value = value.empty? ? 'none' : value.join(', ') if value.is_a?(Array)
          shown(value, 500)
        end

        # One row for each item: the label beside the first, the others below it.
        def rows_for(label, items)
          items.each_with_index.map do |item, index|
            "  #{(index.zero? ? "#{label}:" : '').ljust(LABEL_WIDTH)}#{shown(item, 500)}"
          end
        end

        def verb_changes(before)
          after = verbs
          found = after.filter_map do |call, verb|
            if !before.key?(call)
              "    new call that is not a GET: #{verb} #{shown(call)}" unless verb == 'GET'
            elsif before[call] != verb
              "    #{shown(call)}: #{before[call]} -> #{verb}"
            end
          end
          added = (after.keys - before.keys).size
          removed = (before.keys - after.keys).size
          found << "    calls: #{added} added, #{removed} removed" unless added.zero? && removed.zero?
          found
        end

        def filled(text)
          defaults = @api.variables.transform_values { |spec| spec[:default] }.compact
          text.gsub(Internals::Template::VARIABLE) { defaults.fetch(Regexp.last_match(1).to_sym, Regexp.last_match(0)) }
        end

        # One line for each variable: its default, or that it must be set.
        def variables
          @api.variables.map do |name, spec|
            state = spec[:default] ? "default #{shown(spec[:default], 60)}" : 'to be set'
            "#{name}: #{state}#{", #{shown(spec[:description], 100)}" if spec[:description]}"
          end
        end

        def calls
          total = @api.routes.size
          changing = changing_calls
          return rows_for('calls', ["#{total}, all GET"]) if changing.empty?

          widths = [0, 1].map { |column| changing.map { |call| shown(call[column]).length }.max }
          rows_for('calls', ["#{total}, of which #{changing.size} #{changing.size == 1 ? 'is' : 'are'} not GET:"]) +
            changing.map do |verb, call, path|
              "    #{verb.ljust(widths[0])}  #{shown(call).ljust(widths[1])}  #{shown(path)}"
            end
        end
      end
    end
  end
end
