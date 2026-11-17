# frozen_string_literal: true

module ApiRecipes
  module CLI
    class Recipes
      # What a recipe does, in the lines shown before it is installed: where
      # the requests go, where the credential goes, what is sent with every
      # request, which calls change something. Every text that comes from the
      # recipe goes through shown, and a text that is cut says so: nothing is
      # left out without a sign.
      class Summary
        LABEL_WIDTH = 15
        # The characters shown of a name or a value in a row, of a row, and of
        # a text shown whole: more than a name or a value of a recipe can have.
        PART = 100
        ROW = 500
        WHOLE = 5_000

        # A header or a parameter sent with every request. where: the name of
        # the endpoint that adds it, nil for the api; below: whether that
        # endpoint has others below it, which take it too.
        Sent = Data.define(:name, :value, :where, :below) do
          def key = [name, where]
        end

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
          [title] + rows.reject { |_, text| text.nil? }.flat_map { |label, text| rows_for(label, [text], WHOLE) } +
            rows_for('headers', headers) + rows_for('params', params) + rows_for('variables', variables) + calls
        end

        # What whoever installs the recipe should know before using it.
        def warnings
          found = []
          auth = @api.auth || {}
          if auth[:type] == :query
            found << "the credential travels in the address, as the query parameter #{clip(auth[:name], PART)}: " \
                     'addresses are written in logs and kept by proxies'
          end
          protocol = filled(@api.protocol.to_s)
          if protocol == 'http'
            found << "the protocol is http#{' by default' unless @api.protocol == 'http'}: a credential you assign travels without encryption"
          elsif Internals::OptionValue.variable?(:protocol, protocol)
            found << 'the protocol is a variable without a default: the application chooses it, and with http a ' \
                     'credential you assign travels without encryption'
          end
          found
        end

        # The address as the recipe writes it, with its {variables}.
        def address(fill = false)
          host = fill ? filled(@api.host) : @api.host
          base = @api.base_url.to_s
          base = filled(base) if fill
          path = "/#{base}".gsub(%r{/+}, '/').chomp('/')
          protocol = fill ? filled(@api.protocol.to_s) : @api.protocol
          port = fill && @api.port ? filled(@api.port.to_s) : @api.port
          "#{protocol}://#{host}#{":#{port}" if port}#{path}"
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
        def headers = sent(:headers).map { |one| sent_row(one) }

        # The query parameters sent with every request, in the same form.
        def params = sent(:params).map { |one| sent_row(one) }

        # The headers (:headers) or the parameters (:params) of the api and
        # of its endpoints, as they are written.
        def sent(kind)
          key = kind == :headers ? :default_headers : :default_params
          found = @api.public_send(key).map { |name, value| Sent.new(name.to_s, value.to_s, nil, false) }
          each_endpoint do |node|
            (node.own(key) || {}).each do |name, value|
              found << Sent.new(name.to_s, value.to_s, node.full_name, !node.endpoints.empty?)
            end
          end
          found
        end

        # Each call that is not a GET, as [verb, call, path].
        def changing_calls
          origin = "#{@api.protocol}://#{@api.host}#{":#{@api.port}" if @api.port}"
          @api.routes.reject { |route| route.verb == :get }.map do |route|
            [Internals::OptionValue.shown_verb(route.verb), route.call, route.url.delete_prefix(origin)]
          end
        end

        # Each call as { call => verb }.
        def verbs = @api.routes.to_h { |route| [route.call, Internals::OptionValue.shown_verb(route.verb)] }

        # What this recipe changes in the recipe installed now, whose summary
        # is previous (nil when it is not a valid recipe): the address, the
        # credential, the headers, the parameters and the verbs.
        def changes_from(previous)
          return ['  it replaces a file that is not a valid recipe'] if previous.nil?

          found = [%w[address address], ['with defaults', 'filled_address'], %w[credential credential]].filter_map do |label, reader|
            before = previous.public_send(reader)
            after = public_send(reader)
            "    #{label}: #{clip(before, WHOLE)} -> #{clip(after, WHOLE)}" unless before == after
          end
          found.concat(sent_changes('header', previous.sent(:headers), sent(:headers)))
          found.concat(sent_changes('parameter', previous.sent(:params), sent(:params)))
          found.concat(verb_changes(previous.verbs))
          found << '    no change in the address, the credential, the headers, the parameters or the verbs' if found.empty?
          ["  changes from #{clip(previous.title, PART)}:"] + found
        end

        private

        # text as it can be printed, with at most limit characters; when it
        # has more, the ones shown are followed by how many it has.
        def clip(text, limit)
          whole = self.class.shown(text, WHOLE + 1)
          whole.length > limit ? "#{whole[0, limit]}... (#{whole.length > WHOLE ? "more than #{WHOLE}" : whole.length} characters)" : whole
        end

        def sent_row(one) = "#{clip(one.name, PART)}: #{clip(one.value, PART)}#{place(one, PART)}"

        def place(one, limit)
          one.where ? " (#{clip(one.where, limit)}#{' and below' if one.below})" : ''
        end

        # What changes between two lists of headers or of parameters, a line
        # for each one, compared as they are written and shown whole.
        def sent_changes(word, before, after)
          old = before.to_h { |one| [one.key, one] }
          found = after.filter_map do |one|
            was = old[one.key]
            if was.nil?
              "    new #{word}: #{clip(one.name, WHOLE)}: #{clip(one.value, WHOLE)}#{place(one, WHOLE)}"
            elsif was.value != one.value
              "    #{word} #{clip(one.name, WHOLE)}#{place(one, WHOLE)}: #{clip(was.value, WHOLE)} -> #{clip(one.value, WHOLE)}"
            end
          end
          kept = after.to_h { |one| [one.key, true] }
          found + before.reject { |one| kept.key?(one.key) }.map do |one|
            "    #{word} no longer sent: #{clip(one.name, WHOLE)}#{place(one, WHOLE)}"
          end
        end

        def each_endpoint(level = @api.endpoints, &block)
          level.each_value do |node|
            block.call(node)
            each_endpoint(node.endpoints, &block)
          end
        end

        # One row for each item: the label beside the first, the others below it.
        def rows_for(label, items, limit = ROW)
          items.each_with_index.map do |item, index|
            "  #{(index.zero? ? "#{label}:" : '').ljust(LABEL_WIDTH)}#{clip(item, limit)}"
          end
        end

        def verb_changes(before)
          after = verbs
          found = after.filter_map do |call, verb|
            if !before.key?(call)
              "    new call that is not a GET: #{verb} #{clip(call, WHOLE)}" unless verb == 'GET'
            elsif before[call] != verb
              "    #{clip(call, WHOLE)}: #{before[call]} -> #{verb}"
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
            state = spec[:default] ? "default #{clip(spec[:default], 60)}" : 'to be set'
            "#{clip(name, PART)}: #{state}#{", #{clip(spec[:description], PART)}" if spec[:description]}"
          end
        end

        def calls
          total = @api.routes.size
          changing = changing_calls
          return rows_for('calls', ["#{total}, all GET"]) if changing.empty?

          changing = changing.map { |verb, call, path| [verb, clip(call, ROW), clip(path, WHOLE)] }
          widths = [0, 1].map { |column| changing.map { |call| call[column].length }.max }
          rows_for('calls', ["#{total}, of which #{changing.size} #{changing.size == 1 ? 'is' : 'are'} not GET:"]) +
            changing.map { |verb, call, path| "    #{verb.ljust(widths[0])}  #{call.ljust(widths[1])}  #{path}" }
        end
      end
    end
  end
end
