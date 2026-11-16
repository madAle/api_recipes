# frozen_string_literal: true

module ApiRecipes
  module CLI
    class Recipes
      # What a recipe does, in the lines shown before it is installed: where
      # the requests go, where the credential goes, which calls change
      # something. Every text that comes from the recipe goes through shown.
      class Summary
        LABEL_WIDTH = 15

        # value as it can be printed: one line, without control and format
        # characters, at most limit characters.
        def self.shown(value, limit = 200) = Internals::PlainYaml.label(value, limit)

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
          rows << ['credential', credential] << ['variables', variables]
          [title] + rows.reject { |_, text| text.nil? }.map { |label, text| row(label, text) } + calls
        end

        # What whoever installs the recipe should know before using it.
        def warnings
          found = []
          auth = @api.auth || {}
          if auth[:type] == :query
            found << "the credential travels in the address, as the query parameter #{shown(auth[:name])}: " \
                     'addresses are written in logs and kept by proxies'
          end
          if @api.protocol == 'http' && auth[:type] != :none
            found << 'the protocol is http: the credential travels without encryption'
          end
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

        def credential
          auth = @api.auth || {}
          case auth[:type]
          when :none then 'none: the recipe says that the api takes no credential'
          when :header then "in the header #{auth[:name]}"
          when :query then "in the query string, as the parameter #{auth[:name]}"
          else 'in the Authorization header'
          end
        end

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
        # credential and the verbs.
        def changes_from(previous)
          return ['  it replaces a file that is not a valid recipe'] if previous.nil?

          found = [%w[address address], ['with defaults', 'filled_address'], %w[credential credential]].filter_map do |label, reader|
            before = previous.public_send(reader)
            after = public_send(reader)
            "    #{label}: #{shown(before)} -> #{shown(after)}" unless before == after
          end
          found.concat(verb_changes(previous.verbs))
          found << '    no change in the address, the credential or the verbs' if found.empty?
          ["  changes from #{shown(previous.title, 100)}:"] + found
        end

        private

        def shown(value, limit = 200) = self.class.shown(value, limit)

        def row(label, text) = "  #{"#{label}:".ljust(LABEL_WIDTH)}#{shown(text, 500)}"

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

        def variables
          return nil if @api.variables.empty?

          @api.variables.map do |name, spec|
            notes = []
            notes << (spec[:default] ? "default #{shown(spec[:default], 60)}" : 'to be set')
            notes << shown(spec[:description], 100) if spec[:description]
            "#{name} (#{notes.join(': ')})"
          end.join(', ')
        end

        def calls
          total = @api.routes.size
          changing = changing_calls
          return [row('calls', "#{total}, all GET")] if changing.empty?

          widths = [0, 1].map { |column| changing.map { |call| shown(call[column]).length }.max }
          [row('calls', "#{total}, of which #{changing.size} #{changing.size == 1 ? 'is' : 'are'} not GET:")] +
            changing.map do |verb, call, path|
              "    #{verb.ljust(widths[0])}  #{shown(call).ljust(widths[1])}  #{shown(path)}"
            end
        end
      end
    end
  end
end
