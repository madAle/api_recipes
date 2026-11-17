# frozen_string_literal: true

require 'securerandom'
require 'api_recipes/cli/upgrade/project'

module ApiRecipes
  module CLI
    # Looks for what api_recipes 3.0 removed or changed. It reads files and
    # never writes one. A result carries the file, the line, the kind and a fixed
    # message: never the text of the line, which can hold a secret.
    class Upgrade
      Finding = Data.define(:file, :line, :kind, :message)

      # general: the pattern also matches code that has nothing to do with the
      # gem. In a whole project such a rule is applied only to the files that
      # use the gem.
      Rule = Data.define(:kind, :pattern, :message, :general) do
        def initialize(kind:, pattern:, message:, general: false) = super
      end

      RULES = [
        Rule.new(:breaks, /\.route\b/, 'endpoint.route was removed: use response.fill or endpoint.definition'),
        Rule.new(:breaks, /RouteNameClashWithExistentMethod/,
                 'this error class was removed: a name clash is now a warning'),
        Rule.new(:breaks, /RouteAndResourceNamesClashError|MissingRouteAttribute|ProvidedObjectNotAsResponseData|NoConfigurationGivenForEndpoint/,
                 'this error class was removed: nothing raised it, so the rescue clause can go'),
        Rule.new(:breaks, /\.base_configs\b/, 'Api#base_configs was removed: use api.definition'),
        Rule.new(:breaks, /ApiRecipes::Route\b/, 'ApiRecipes::Route was removed: a request is sent with run'),
        Rule.new(:breaks, /ApiRecipes::Settings\b/,
                 'ApiRecipes::Settings was removed: the defaults are listed in the README'),
        Rule.new(:breaks, /\bconfiguration\.setup\b/,
                 'configuration.setup was removed: configure loads the configuration'),
        Rule.new(:breaks, /ApiRecipes\.print_urls/, 'use config.print_urls inside ApiRecipes.configure'),
        Rule.new(:breaks, /_aprcps_|set_authorization_for_api|set_basic_auth_for_api|copy_global_authorizations_to_api/,
                 'internal method removed'),
        Rule.new(:breaks, /\bApiRecipes((\.|::)\w+|\[[^\]]*\])\.(authorization|basic_auth)\s*(\|\|)?=(?![=~])/,
                 'a credential of the whole application is given to ApiRecipes.configure, as ' \
                 'config.values = { name: { authorization: ... } }: this writer now raises'),
        Rule.new(:check, /(?<!\bApiRecipes)\.\w+\.(authorization|basic_auth)\s*(\|\|)?=(?![=~])/,
                 'authorization= and basic_auth= now work on an object only: on a class they raise, ' \
                 'give the credential to `api :name, authorization: ...`, or to with(...) for one request'),
        Rule.new(:check, /url_encode|CGI\.escape|encode_www_form_component/,
                 'path parameters are now encoded by ApiRecipes: remove manual encoding of values passed to endpoints', true),
        Rule.new(:check, /\brescue\s*(=>.*)?$|rescue StandardError/,
                 'a bare rescue now catches ApiRecipes errors too', true),
        Rule.new(:check, /\bfollow:/, 'credentials are no longer sent to another origin after a redirect', true),
        Rule.new(:check, /\bresponse\.request\b/,
                 'response.request was removed, because the request holds the credentials: ' \
                 'read response.uri, or response.original_response', true),
        Rule.new(:check, /\.(deep_merge|deep_symbolize_keys|deep_stringify_keys|symbolize_keys|stringify_keys|extract_options!|assert_valid_keys)\b/,
                 'this method came from api_recipes 2.x unless ActiveSupport is loaded: ' \
                 'define it or add ActiveSupport', true)
      ].freeze

      # The rule about the Hash methods that ActiveSupport defines too.
      HASH_METHODS = RULES.last

      # What stands for the value of an ERB tag in a file that is checked
      # without running its code.
      # Options whose value is a mapping: a tag that gives one gives a part
      # of the structure, which is not guessed.
      CONTAINERS = %w[variables endpoints default_headers default_params auth recipe resource].freeze
      ERB_COMMENT = /<%#.*?%>/m
      ERB_OUTPUT = /<%=.*?%>/m

      SILENT_CHANGES = [
        'path parameters encoded by hand: %2F would become %252F, remove the encoding',
        'a / inside a path parameter to cover several segments: use *name or two placeholders',
        'debug logs or print_urls output read from STDOUT: set log_to and log_level',
        'a bare rescue around a call: it now catches the errors of the gem too',
        'credentials assigned on an instance: they now take effect',
        'a credential assigned through a variable that holds the api of the module or of a class (api = ApiRecipes.github, then api.authorization = ...), inside the body of a class (github.authorization = ...), with send, or on a statement split over two lines: the writer raises, give it to config.values or to `api :name, authorization: ...`',
        'the response body read from the message of a verify_with error: read it from error.response',
        'a block passed to run whose return value is used: it is now the Response',
        'apis_configs assigned after the files to discard them: do not assign the files',
        'timeout, on_bad_code, mime_type or verify_with on an endpoint that contains other endpoints: one that does not set the option now finds it there, before the api',
        'an endpoint called with, definition, authorization, basic_auth or variables (on an api), or run, url, with or definition (on an endpoint): reach it with []; the warning at configuration reports it',
        'fill with private setters, or code that relies on swallowed errors: make the setters public, handle the errors',
        'follow: true together with a credential: the credential no longer follows to another host',
        'a class with its own host, protocol or port that relied on the global credential: set the credential on the class',
        'cookies set by a server during a redirect chain: they are no longer carried to the next hop',
        'api names that are methods of Kernel, such as :open or :format: they raise ApiNameClashError, use as:',
        'Endpoint#name, #params, #children, #api and Api#name, #configs, #object were removed: use definition (a search cannot tell them from other methods called like that)',
        'an object restored from a serialized form (Marshal, YAML) has no credential: assign it again',
        'response.uri leaves out the credential query parameter when the api declares auth type query',
        'a redirect to a host with non-ASCII characters needs the addressable gem: without it the request raises InvalidUrl',
        'a base_url with a placeholder in a configuration given as a Hash: it is now an error, use a variable',
        'response.request was removed, whatever the name of the variable that holds the response: the request holds the credentials, read response.uri or response.original_response',
        'response.to_s returns the body, as the http.rb response does: it was the default text of the object',
        'a credential that is not a String, such as a Symbol or a number: it raises InvalidCredential, convert it with to_s',
        'a {word} in a value of default_headers in a configuration given as a Hash: it is now a variable and must be declared',
        'a {word} in the path of an endpoint in a configuration given as a Hash: it is now a variable and must be declared; to keep the braces as text write \\{word}',
        'respond_to? on a response now tells the truth: it answers true for the methods the response forwards and false for the others',
        'serializing an Api, an Endpoint or a Response raises TypeError: serialize response.data or response.body.to_s',
        'a class that includes ApiRecipes and uses a top-level constant named Error, Internals, VERSION or like a new error class of the gem (such as ConfigurationError or InvalidUrl): it now finds the gem\'s constant first, write ::Name in that class; Route and Settings no longer exist, so a top-level Route or Settings is found again'
      ].freeze

      # Problems met while reading, as "<file>: <reason>". They are not findings:
      # the file could not be checked.
      attr_reader :warnings

      # What was checked and how, said after the findings. Not findings.
      attr_reader :notes

      # project: the Project the paths and the files were found in, when the
      # command was given none.
      def initialize(paths, config: [], erb: false, project: nil)
        @paths = Array(paths)
        @configs = Array(config)
        @erb = erb
        @project = project
        @warnings = []
        @notes = []
        # What stands for the value of an ERB tag in a file that is checked
        # without running its code: random, so that no file can write it.
        @erb_value = "API_RECIPES_ERB_VALUE_#{SecureRandom.hex(6)}"
      end

      # The command without arguments: the project in the current directory.
      def self.for_project(project, erb: false)
        new(project.ruby_files, config: project.config_files, erb: erb, project: project)
      end

      def run
        @warnings = @project ? @project.warnings.dup : []
        @notes = []
        @uses = 0
        findings = @paths.flat_map { |path| scan_path(path) }
        findings += @configs.flat_map { |file| check_config(file) }
        @notes = scope + @notes if @project
        findings
      end

      # Prints the results on out and the warnings on err. Returns the exit code.
      def report(out, err)
        findings = run
        findings.each { |finding| out.puts format_finding(finding) }
        unless @notes.empty?
          out.puts unless findings.empty?
          @notes.each { |note| out.puts note }
        end
        out.puts
        out.puts 'What this command cannot find'
        SILENT_CHANGES.each { |change| out.puts "  - #{change}" }
        out.puts
        @warnings.each { |warning| err.puts warning }
        out.puts summary(findings.size) if findings.any? || @warnings.empty?
        return 1 if findings.any?

        @warnings.empty? ? 0 : 2
      end

      private

      def summary(count)
        case count
        when 0 then nothing_found
        when 1 then '1 finding'
        else "#{count} findings"
        end
      end

      # "Nothing to change" is said only of what was checked.
      def nothing_found
        return 'Nothing to change' unless @project && @configs.empty?

        'Nothing to change in the Ruby files. No configuration file was found: if the apis are described in ' \
          'YAML files, name each one with --config FILE'
      end

      # What a run on a project looked at.
      def scope
        ruby = @paths.size
        lines = ["Checked #{ruby} Ruby file#{'s' unless ruby == 1}, #{@uses} of them use#{'s' if @uses == 1} api_recipes"]
        lines << if @configs.empty?
                   'No configuration file was found'
                 else
                   "Checked #{@configs.size} configuration file#{'s' unless @configs.size == 1}: #{@configs.map { |file| shown_path(file) }.join(', ')}"
                 end
        lines + @project.undescribed.map do |declared|
          "#{shown_path(declared.file)}:#{declared.line}: declares the api '#{declared.api}', and no configuration file found here describes it"
        end
      end

      # A name found in the project is shown without what a terminal would
      # obey; a path that was given is shown as it was given.
      def shown_path(file) = @project ? Recipes::Summary.shown(file, 300) : file

      def format_finding(finding)
        file = shown_path(finding.file)
        where = finding.line ? "#{file}:#{finding.line}" : file
        "#{where}: [#{finding.kind}] #{finding.message}"
      end

      def scan_path(path)
        if File.directory?(path)
          Dir.glob('**/*.{rb,rake}', base: path).sort.flat_map do |relative|
            file = File.join(path, relative)
            File.directory?(file) ? [] : scan_file(file)
          end
        elsif File.exist?(path)
          scan_file(path)
        else
          @warnings << "#{path}: no such file or directory"
          []
        end
      end

      def scan_file(file)
        text = read_ruby(file)
        return [] unless text

        rules = rules_for(text)
        found = []
        text.each_line(chomp: true).with_index(1) do |line, number|
          rules.each do |rule|
            found << Finding.new(file: file, line: number, kind: rule.kind, message: rule.message) if rule.pattern.match?(line)
          end
        end
        found
      end

      # Every rule for the paths that were given. In a project, the general
      # ones only for a file that uses the gem, and never the one about the
      # methods that ActiveSupport defines when the project has it.
      def rules_for(text)
        return RULES unless @project

        @specific ||= RULES.reject(&:general)
        @all ||= @project.active_support? ? RULES - [HASH_METHODS] : RULES
        return @specific unless @project.uses_gem?(text)

        @uses += 1
        @all
      end

      # Returns the text, or nil after recording why the file was not checked.
      def read_ruby(file)
        bytes = File.binread(file)
        if bytes.include?("\0")
          @warnings << "#{file}: binary file, not checked"
          return nil
        end
        text = bytes.force_encoding(Encoding::UTF_8)
        return text if text.valid_encoding?

        @warnings << "#{file}: not valid UTF-8, not checked"
        nil
      rescue SystemCallError => e
        @warnings << "#{file}: cannot read (#{e.class.name.split('::').last})"
        nil
      end

      def check_config(file)
        return check_recipe(file) if file.end_with?(Internals::Recipe::SUFFIX)
        return [config_finding(file, 'describes more values than can be checked: aliases make them from a few lines')] if too_many_values?(file)

        unchecked = []
        tags = false
        apis = Configuration.new.read_recipe_file(file, erb: @erb) do |text|
          tags = true
          without_erb(file, text)
        end
        return not_checked(file) if tags && structural_tag?(apis)

        unchecked = erb_values(apis)
        Internals::Compiler.compile_all(apis)
        note_unchecked(file, unchecked)
        []
      rescue RecipeFileError => e
        return not_checked(file) if tags && e.errors.all? { |problem| problem.include?('invalid YAML') }

        e.errors.map { |problem| config_finding(file, problem.delete_prefix("#{file}: ")) }
      rescue ConfigurationError => e
        note_unchecked(file, unchecked)
        checked(e.errors, unchecked).map { |problem| config_finding(file, problem) }
      rescue SystemStackError
        [config_finding(file, 'is nested too deeply to be checked')]
      rescue StandardError, ScriptError => e
        [config_finding(file, "could not be evaluated (#{e.class})")]
      end

      # A file whose tags give a name or a part of the structure is not
      # guessed: it is said, and it is not a finding.
      def not_checked(file)
        @notes << "#{shown_path(file)}: an ERB tag gives a name or a part of the structure: not checked without --erb"
        []
      end

      def structural_tag?(value)
        case value
        when Hash
          value.any? do |key, inner|
            key.to_s.include?(@erb_value) || (CONTAINERS.include?(key.to_s) && inner.to_s == @erb_value) || structural_tag?(inner)
          end
        when Array then value.any? { |inner| structural_tag?(inner) }
        else false
        end
      end

      # Aliases can make millions of values from a few lines: the file is
      # measured, with its tags read as a word, before anything walks it.
      def too_many_values?(file)
        text = File.binread(file).force_encoding(Encoding::UTF_8)
        return false unless text.valid_encoding? && text.include?('*')

        data = YAML.safe_load(text.gsub(/<%.*?%>/m, 'erb'), permitted_classes: [Symbol], aliases: true)
        !Project.within?(data, Project::MAX_VALUES)
      rescue SystemCallError, Psych::Exception, SystemStackError
        false
      end

      # A file called NAME.recipe.yml is a portable recipe, read as data only.
      def check_recipe(file)
        Internals::Recipe.read(file)
        []
      rescue ConfigurationError => e
        e.errors.map { |problem| config_finding(file, problem.delete_prefix("#{file}: ")) }
      rescue StandardError => e
        [config_finding(file, "could not be read (#{e.class})")]
      end

      # The text of a file with ERB, made checkable without running anything:
      # the value of each output tag becomes ERB_VALUE. A tag that is not an
      # output tag can decide which lines the file has, so it is not guessed.
      def without_erb(file, text)
        plain = text.gsub(ERB_COMMENT, '').gsub(ERB_OUTPUT, @erb_value)
        return plain.gsub('<%%', '<%') unless plain.gsub('<%%', '').include?('<%')

        raise RecipeFileError.new(file, 'contains ERB that decides the structure of the file (<% ... %>): run again ' \
                                       'with --erb to evaluate it (this executes the code in the file)')
      end

      # The places, as the compiler names them, whose value holds the value
      # of a tag.
      def erb_values(value, path = nil, found = [])
        case value
        when Hash then value.each { |key, inner| erb_values(inner, [path, place(key)].compact.join('.'), found) }
        when Array then found << path if value.any? { |item| item.to_s.include?(@erb_value) }
        else found << path if value.to_s.include?(@erb_value)
        end
        found
      end

      # A name as the compiler writes it in the place of a problem.
      def place(name) = name.to_s.gsub(/[^[:print:]]/, '?')[0, 40]

      # The problems that are not about a value that an ERB tag gives.
      def checked(problems, unchecked)
        problems.reject { |problem| unchecked.any? { |path| problem.start_with?("#{path}: ") } }
      end

      def note_unchecked(file, unchecked)
        return if unchecked.empty?

        count = unchecked.size
        @notes << "#{shown_path(file)}: #{count} value#{'s' unless count == 1} come#{'s' if count == 1} from ERB and " \
                  "#{count == 1 ? 'was' : 'were'} not checked"
      end

      def config_finding(file, message)
        Finding.new(file: file, line: nil, kind: :config, message: message)
      end
    end
  end
end
