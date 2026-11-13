# frozen_string_literal: true

module ApiRecipes
  module CLI
    # Looks for what api_recipes 3.0 removed or changed. It reads files and
    # never writes one. A result carries the file, the line, the kind and a fixed
    # message: never the text of the line, which can hold a secret.
    class Upgrade
      Finding = Data.define(:file, :line, :kind, :message)

      Rule = Data.define(:kind, :pattern, :message)

      RULES = [
        Rule.new(:breaks, /\.route\b/, 'endpoint.route was removed: use response.fill or endpoint.definition'),
        Rule.new(:breaks, /RouteNameClashWithExistentMethod/,
                 'this error class was removed: a name clash is now a warning'),
        Rule.new(:breaks, /RouteAndResourceNamesClashError|MissingRouteAttribute|ProvidedObjectNotAsResponseData|NoConfigurationGivenForEndpoint/,
                 'this error class was removed: nothing raised it, so the rescue clause can go'),
        Rule.new(:breaks, /\.base_configs\b/, 'Api#base_configs was removed: use api.definition'),
        Rule.new(:breaks, /ApiRecipes\.print_urls/, 'use config.print_urls inside ApiRecipes.configure'),
        Rule.new(:breaks, /_aprcps_|set_authorization_for_api|set_basic_auth_for_api|copy_global_authorizations_to_api/,
                 'internal method removed'),
        Rule.new(:check, /url_encode|CGI\.escape|encode_www_form_component/,
                 'path parameters are now encoded by ApiRecipes: remove manual encoding of values passed to endpoints'),
        Rule.new(:check, /\brescue\s*(=>.*)?$|rescue StandardError/,
                 'a bare rescue now catches ApiRecipes errors too'),
        Rule.new(:check, /\bfollow:/, 'credentials are no longer sent to another origin after a redirect'),
        Rule.new(:check, /\.(deep_merge|deep_symbolize_keys|deep_stringify_keys|symbolize_keys|stringify_keys|extract_options!|assert_valid_keys)\b/,
                 'this method came from api_recipes 2.x unless ActiveSupport is loaded: ' \
                 'define it or add ActiveSupport')
      ].freeze

      SILENT_CHANGES = [
        'path parameters encoded by hand: %2F would become %252F, remove the encoding',
        'a / inside a path parameter to cover several segments: use *name or two placeholders',
        'debug logs or print_urls output read from STDOUT: set log_to and log_level',
        'a bare rescue around a call: it now catches the errors of the gem too',
        'credentials assigned on a class or an instance: they now take effect',
        'the response body read from the message of a verify_with error: read it from error.response',
        'a block passed to run whose return value is used: it is now the Response',
        'apis_configs assigned after the files to discard them: do not assign the files',
        'a nested endpoint without options under a parent with verify_with: it now inherits the verification',
        'an endpoint called with, definition, authorization, basic_auth or variables (on an api), or run, url, with or definition (on an endpoint): reach it with []; the warning at configuration reports it',
        'fill with private setters, or code that relies on swallowed errors: make the setters public, handle the errors',
        'follow: true together with a credential: the credential no longer follows to another host',
        'a class with its own host, protocol or port that relied on the global credential: set the credential on the class',
        'cookies set by a server during a redirect chain: they are no longer carried to the next hop',
        'api names that are methods of Kernel, such as :open or :format: they raise ApiNameClashError, use as:',
        'Endpoint#name, #params, #children, #api and Api#name, #configs, #object were removed: use definition (a search cannot tell them from other methods called like that)',
        'an object restored from a serialized form (Marshal, YAML) has no credential: assign it again',
        'response.uri leaves out the credential query parameter when the api declares auth type query',
        'a redirect to a host with non-ASCII characters needs the addressable gem',
        'a base_url with a placeholder in a configuration given as a Hash: it is now an error, use a variable'
      ].freeze

      # Problems met while reading, as "<file>: <reason>". They are not findings:
      # the file could not be checked.
      attr_reader :warnings

      def initialize(paths, config: [], erb: false)
        @paths = Array(paths)
        @configs = Array(config)
        @erb = erb
        @warnings = []
      end

      def run
        @warnings = []
        findings = @paths.flat_map { |path| scan_path(path) }
        findings + @configs.flat_map { |file| check_config(file) }
      end

      # Prints the results on out and the warnings on err. Returns the exit code.
      def report(out, err)
        findings = run
        findings.each { |finding| out.puts format_finding(finding) }
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
        when 0 then 'Nothing to change'
        when 1 then '1 finding'
        else "#{count} findings"
        end
      end

      def format_finding(finding)
        where = finding.line ? "#{finding.file}:#{finding.line}" : finding.file
        "#{where}: [#{finding.kind}] #{finding.message}"
      end

      def scan_path(path)
        if File.directory?(path)
          Dir.glob('**/*.rb', base: path).sort.flat_map do |relative|
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

        found = []
        text.each_line(chomp: true).with_index(1) do |line, number|
          RULES.each do |rule|
            found << Finding.new(file: file, line: number, kind: rule.kind, message: rule.message) if rule.pattern.match?(line)
          end
        end
        found
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
        apis = Configuration.new.read_recipe_file(file, erb: @erb)
        Compiler.compile_all(apis)
        []
      rescue RecipeFileError => e
        e.errors.map { |problem| config_finding(file, problem.delete_prefix("#{file}: ")) }
      rescue ConfigurationError => e
        e.errors.map { |problem| config_finding(file, problem) }
      rescue StandardError, ScriptError => e
        [config_finding(file, "could not be evaluated (#{e.class})")]
      end

      def config_finding(file, message)
        Finding.new(file: file, line: nil, kind: :config, message: message)
      end
    end
  end
end
