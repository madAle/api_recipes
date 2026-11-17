# frozen_string_literal: true

require 'yaml'

module ApiRecipes
  module CLI
    # The convert command: from a configuration file of a project to the text
    # of a portable recipe. The file is read and never run: an ERB tag becomes
    # a variable where a recipe can have one, and is left out elsewhere. What
    # is named like a credential is never copied. The result is checked as a
    # portable recipe before it is returned.
    class Convert
      # The file cannot become a recipe. reasons: one line each.
      class Refused < StandardError
        attr_reader :reasons

        def initialize(reasons)
          @reasons = Array(reasons)
          super(@reasons.join("\n"))
        end
      end

      # The arguments are wrong, or the file cannot be read.
      class Unusable < StandardError; end

      # variables: { name => environment variable or nil } for those without a
      # default; defaults: the same for those that have one.
      Result = Data.define(:name, :version, :text, :calls, :changes, :variables, :defaults)

      Tag = Data.define(:line, :env, :default)

      DEFAULT_VERSION = '1.0.0'
      COMMENT = /<%#.*?%>/m
      OUTPUT = /<%=(.*?)-?%>/m
      TOKEN = /__API_RECIPES_ERB_(\d+)__/
      ENV_READ = /\A\s*ENV(?:\.fetch\(\s*|\[\s*)(['"])([A-Za-z_][A-Za-z0-9_]*)\1\s*(?:,\s*(.*?))?\s*[\])]\s*\z/m
      # A header or a parameter with such a name holds a credential.
      CREDENTIAL = /auth|key|token|secret|passw|credential|signature|cookie|session/i
      SENT = %w[default_headers default_params].freeze
      API_ORDER = %w[recipe auth variables protocol host port base_url timeout on_bad_code mime_type
                     default_headers default_params].freeze
      ENDPOINT_ORDER = %w[path verb route ok_code resource timeout on_bad_code mime_type default_headers default_params].freeze

      def initialize(file, name: nil, version: DEFAULT_VERSION)
        @file = file
        @wanted = name
        @version = version
      end

      def call
        raise Unusable, '--version: must be made of digits, letters and dots, such as 1.2.0' unless version_valid?
        raise Unusable, "#{shown(@file)}: is already called #{Internals::Recipe::SUFFIX}: check it with `api_recipes check`" if @file.end_with?(Internals::Recipe::SUFFIX)

        @changes = []
        @variables = {}
        @origins = {}
        @envs = {}
        name, options = api(parsed(plain(source)))
        @name = name
        declared = options['variables']
        declared.each_key { |variable| @origins[variable.to_s] = :declared } if declared.is_a?(Hash)
        refuse('the name of the api must be made of lowercase letters, digits, - and _ to be the name of a recipe') unless Internals::Recipe::NAME.match?(name)
        refuse('already has the key recipe: rename the file to NAME.recipe.yml and check it') if options.key?('recipe')

        body = api_options(options)
        body = { 'recipe' => { 'name' => name, 'version' => @version, 'format' => Internals::Recipe::FORMAT } }.merge(body)
        body['variables'] = (body['variables'] || {}).merge(@variables) unless @variables.empty?
        text = Text.new(name, ordered(body, API_ORDER)).to_yaml
        Result.new(name: name, version: @version, text: text, calls: checked(name, text), changes: @changes,
                   variables: env_of(false), defaults: env_of(true))
      end

      # What is said after the recipe is written in path: what changed from
      # the file, and what the application gives from now on. It holds names
      # only, never a value of the file.
      def self.report(result, source, path)
        calls = result.calls
        lines = ["#{result.name} #{result.version} is written in #{path}: #{calls} call#{'s' unless calls == 1}"]
        unless result.changes.empty?
          lines << '' << "What changed from #{Recipes::Summary.shown(source, 100)}"
          lines.concat(result.changes.map { |change| "  #{change}" })
        end
        given = ->(variables) { variables.map { |name, env| "#{name}: #{env ? "ENV.fetch('#{env}')" : "'...'"}" } }
        unless result.variables.empty?
          lines << '' << 'In the application, the variables that have no default:'
          lines << "  config.values = { #{result.name}: { variables: { #{given.call(result.variables).join(', ')} } } }"
        end
        unless result.defaults.empty?
          lines << '' << 'Variables with a default, to give only where the value is another:'
          lines.concat(given.call(result.defaults).map { |one| "  #{one}" })
        end
        lines << '' << "Read the file, then check it: api_recipes check #{path}"
        lines
      end

      private

      def shown(text) = Recipes::Summary.shown(text, 100)

      def refuse(reasons) = raise(Refused.new(Array(reasons).map { |reason| "#{shown(@file)}: #{reason}" }))

      def version_valid?
        @version.is_a?(String) && @version.length <= Internals::Recipe::MAX_VERSION && Internals::Recipe::VERSION.match?(@version)
      end

      def source
        raise Unusable, "#{shown(@file)}: no such file" unless File.exist?(@file)
        raise Unusable, "#{shown(@file)}: is not a file that can be read" unless File.file?(@file) && File.readable?(@file)
        raise Unusable, "#{shown(@file)}: is larger than a recipe can be" if File.size(@file) > Internals::Recipe::MAX_BYTES

        text = File.binread(@file).force_encoding(Encoding::UTF_8)
        refuse('is not text') if text.include?("\0") || !text.valid_encoding?
        text
      rescue SystemCallError => e
        raise Unusable, "#{shown(@file)}: cannot be read (#{e.class.name.split('::').last})"
      end

      # The text with each output tag replaced by a token, and the tags kept
      # aside. Nothing of a tag is run.
      def plain(text)
        refuse('holds text that this command uses for itself') if TOKEN.match?(text)
        @tags = []
        plain = text.gsub(COMMENT) { |comment| comment.gsub(/[^\n]/, '') }
        plain = plain.gsub(OUTPUT) do
          code = Regexp.last_match(1)
          @tags << tag(code, Regexp.last_match.pre_match.count("\n") + 1)
          "__API_RECIPES_ERB_#{@tags.size - 1}__#{"\n" * code.count("\n")}"
        end
        left = plain.gsub('<%%', '')
        return plain.gsub('<%%', '<%') unless left.include?('<%')

        lines = left.each_line.with_index(1).select { |line, _| line.include?('<%') }.map(&:last)
        raise Refused.new(lines.map do |line|
          "#{shown(@file)}:#{line}: an ERB tag that is not <%= ... %> decides the structure of the file: " \
            'write the file without it first'
        end)
      end

      # What can be known of a tag without running it: the environment
      # variable it reads and the default written beside it.
      def tag(code, line)
        match = ENV_READ.match(code)
        return Tag.new(line: line, env: nil, default: nil) unless match

        Tag.new(line: line, env: match[2], default: literal(match[3]))
      end

      def literal(code)
        case code
        when /\A'([^'\\]*)'\z/, /\A"([^"\\#]*)"\z/ then Regexp.last_match(1)
        when /\A\d+\z/ then code.to_i
        when /\A\d+\.\d+\z/ then code.to_f
        when 'true' then true
        when 'false' then false
        end
      end

      def parsed(text)
        data = YAML.safe_load(text, permitted_classes: [Symbol], aliases: true)
        refuse('does not describe an api') unless data.is_a?(Hash) && !data.empty?
        named = names_from_tags(data)
        unless named.empty?
          raise Refused.new(named.map { |line| "#{shown(@file)}:#{line}: an ERB tag gives a name: a recipe needs the name written" })
        end

        stringify(data)
      rescue Psych::SyntaxError => e
        refuse("is not valid YAML, at line #{e.line}")
      rescue Psych::Exception
        refuse('is not valid YAML')
      end

      # The lines of the tags that stand where a name does.
      def names_from_tags(value, found = [])
        case value
        when Hash
          value.each do |key, inner|
            key.to_s.scan(TOKEN) { found << @tags[Regexp.last_match(1).to_i].line }
            names_from_tags(inner, found)
          end
        when Array then value.each { |inner| names_from_tags(inner, found) }
        end
        found
      end

      def stringify(value)
        case value
        when Hash then value.to_h { |key, inner| [key.to_s, stringify(inner)] }
        when Array then value.map { |inner| stringify(inner) }
        when Symbol then value.to_s
        else value
        end
      end

      def api(data)
        names = data.keys
        if @wanted
          raise Unusable, "#{shown(@file)}: does not describe an api called #{shown(@wanted)}" unless data.key?(@wanted)

          return [@wanted, data[@wanted] || {}]
        end
        unless names.size == 1
          raise Unusable, "#{shown(@file)}: describes #{names.size} apis (#{names.map { |name| shown(name) }.join(', ')}): choose one with --name"
        end

        refuse('does not describe an api') unless data[names.first].is_a?(Hash)
        [names.first, data[names.first]]
      end

      def api_options(options)
        out = {}
        options.each do |key, value|
          case key
          when 'verify_with' then left_out(key)
          when 'host', 'base_url' then out[key] = with_variables(value, key, key)
          when *SENT then out[key] = sent(value, key)
          when 'endpoints' then out[key] = endpoints(value, key)
          else keep(out, key, value, key)
          end
        end
        out
      end

      def endpoints(value, where)
        return value unless value.is_a?(Hash)

        value.to_h do |name, options|
          here = "#{where}.#{name}"
          [name, options.is_a?(Hash) ? ordered(endpoint(options, here, name), ENDPOINT_ORDER) : fixed(options, here)]
        end
      end

      def endpoint(options, where, name)
        out = {}
        options.each do |key, value|
          here = "#{where}.#{key}"
          case key
          when 'verify_with' then left_out(here)
          when 'path' then out[key] = with_variables(value, here, "#{name}_path")
          when *SENT then out[key] = sent(value, here)
          when 'endpoints' then out[key] = endpoints(value, here)
          else keep(out, key, value, here)
          end
        end
        out
      end

      def left_out(where)
        @changes << "#{shown(where)}: left out, a recipe cannot carry it: give it where a class declares the api, " \
                    "as `api :#{@name}, verify_with: ...`"
      end

      # Headers and parameters: a tag becomes a variable, and what is named
      # like a credential is never copied.
      def sent(value, where)
        return fixed(value, where) unless value.is_a?(Hash)

        value.to_h do |name, content|
          here = "#{where}.#{name}"
          if CREDENTIAL.match?(name)
            [name, credential(content, here, name)]
          else
            [name, with_variables(content, here, name)]
          end
        end
      end

      def credential(content, where, name)
        tags = content.to_s.scan(TOKEN).flatten.map { |index| @tags[index.to_i] }
        if tags.size == 1 && content.to_s.match?(/\A#{TOKEN.source}\z/)
          variable = variable_for(tags.first, name, default: false)
          @changes << "#{shown(where)}: the ERB tag is now the variable {#{variable}}; the value is not in the recipe"
        else
          variable = declare(variable_name(name), nil, nil)
          @changes << "#{shown(where)}: looks like a credential: its value is not copied, it is now the variable {#{variable}}"
        end
        "{#{variable}}"
      end

      # A value where a recipe can have a variable.
      def with_variables(value, where, fallback)
        return fixed(value, where) unless value.is_a?(String) && TOKEN.match?(value)

        value.gsub(TOKEN) do
          tag = @tags[Regexp.last_match(1).to_i]
          variable = variable_for(tag, fallback, default: true)
          kept = @variables[variable].key?('default') ? ', with the default written in the tag' : ''
          @changes << "#{shown(where)}: the ERB tag is now the variable {#{variable}}#{kept}"
          "{#{variable}}"
        end
      end

      def variable_for(tag, fallback, default:)
        declare(variable_name(tag.env || fallback), tag.env, default ? tag.default : nil)
      end

      def variable_name(text)
        name = text.to_s.downcase.gsub(/[^a-z0-9_]+/, '_').gsub(/\A_+|_+\z/, '')
        name = "v_#{name}" unless name.match?(/\A[a-z_]/)
        name
      end

      # Declares the variable and returns its name. The same environment
      # variable, or the same place, gives the same variable.
      def declare(name, env, default)
        origin = env || name
        taken = @origins.key(origin)
        return taken if taken

        base = name
        number = 1
        name = "#{base}_#{number += 1}" while @origins.key?(name)
        @origins[name] = origin
        @variables[name] = default.nil? ? {} : { 'default' => default.to_s }
        @envs[name] = env
        name
      end

      def env_of(with_default)
        @variables.select { |_, spec| spec.key?('default') == with_default }.keys.sort.to_h { |name| [name, @envs[name]] }
      end

      # Any other option: a recipe cannot have a variable there.
      def keep(out, key, value, where)
        unless holds_tag?(value)
          out[key] = value
          return
        end

        tag = value.is_a?(String) && (match = /\A#{TOKEN.source}\z/.match(value)) ? @tags[match[1].to_i] : nil
        if tag && !tag.default.nil?
          out[key] = tag.default
          @changes << "#{shown(where)}: came from an ERB tag: the recipe has the default written in the tag"
        else
          @changes << "#{shown(where)}: came from an ERB tag with no default that can be read without running it: " \
                      'left out, so the default of the gem applies; write the value in the recipe if it is always the same'
        end
      end

      def fixed(value, where)
        return value unless holds_tag?(value)

        refuse("#{where}: an ERB tag gives a value that a recipe needs written")
      end

      def holds_tag?(value)
        case value
        when Hash then value.any? { |key, inner| TOKEN.match?(key.to_s) || holds_tag?(inner) }
        when Array then value.any? { |inner| holds_tag?(inner) }
        when String then TOKEN.match?(value)
        else false
        end
      end

      def ordered(options, order)
        first = order.select { |key| options.key?(key) }
        (first + (options.keys - first - ['endpoints']) + (options.key?('endpoints') ? ['endpoints'] : [])).to_h { |key| [key, options[key]] }
      end

      # The result must be a portable recipe. Returns the number of its calls.
      def checked(name, text)
        file_name = "#{name}#{Internals::Recipe::SUFFIX}"
        Internals::Recipe.parse(text, file_name, file_name: file_name).definition.routes.size
      rescue ConfigurationError => e
        problems = e.errors.map { |problem| problem.delete_prefix("#{file_name}: ") }
        raise Refused.new(["#{shown(@file)} cannot become a portable recipe:"] + problems.map { |problem| "  #{problem}" })
      end

      # The text of the recipe. Every name and every value is written by Ruby's
      # YAML generator, on one line, and the text is read back and compared
      # with the data before it is returned.
      class Text
        INTERNAL = 'internal error: the recipe does not read back as it was written, so nothing was written'

        def initialize(name, options)
          @name = name
          @options = options
        end

        def to_yaml
          @lines = []
          write(0, @name, @options)
          text = "#{@lines.join("\n")}\n"
          raise Refused.new([INTERNAL]) unless YAML.safe_load(text) == { @name => @options }

          text
        rescue Psych::Exception
          raise Refused.new([INTERNAL])
        end

        private

        def write(indent, key, value)
          key = scalar(key)
          case value
          when Hash
            if value.empty?
              line(indent, "#{key}: {}")
            else
              line(indent, "#{key}:")
              value.each { |name, inner| write(indent + 1, name, inner) }
            end
          when Array then line(indent, "#{key}: [#{value.map { |item| scalar(item) }.join(', ')}]")
          when nil then line(indent, "#{key}:")
          else line(indent, "#{key}: #{scalar(value)}")
          end
        end

        def line(indent, text) = @lines << "#{'  ' * indent}#{text}"

        def scalar(content)
          plain = content.is_a?(String) || content.is_a?(Integer) || content.is_a?(Float) || content == true || content == false
          raise Refused.new(['a value of the file is not text, a number, true or false: a recipe holds nothing else']) unless plain

          written = YAML.dump([content], line_width: -1)[/\A---\n- (.*)\n\z/m, 1]
          raise Refused.new(['a name or a value of the file takes more than one line: a recipe holds one line each']) if written.nil? || written.include?("\n")

          written
        end
      end
    end
  end
end
