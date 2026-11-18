# frozen_string_literal: true

require 'securerandom'
require 'api_recipes/cli/upgrade/project'
require 'api_recipes/cli/upgrade/screen'
require 'api_recipes/cli/upgrade/fix'

module ApiRecipes
  module CLI
    # Looks for what api_recipes 3.0 removed or changed. It reads files and
    # never writes one. A result carries the file, the line, the kind and a fixed
    # message: never the text of the line, which can hold a secret.
    class Upgrade
      # hint: lines of code shown under the finding, or nil.
      Finding = Data.define(:file, :line, :kind, :message, :hint) do
        def initialize(file:, line:, kind:, message:, hint: nil) = super
      end

      # general: the pattern also matches code that has nothing to do with the
      # gem. In a whole project such a rule is applied only to the files that
      # use the gem.
      # fix: which code to paste the line gives, when it gives one.
      Rule = Data.define(:kind, :pattern, :message, :general, :fix) do
        def initialize(kind:, pattern:, message:, general: false, fix: nil) = super
      end

      RULES = [
        Rule.new(:breaks, /\.route\b/, 'endpoint.route was removed: use response.fill or endpoint.definition', false, :route),
        Rule.new(:breaks, /RouteNameClashWithExistentMethod/,
                 'this error class was removed: a name clash is now a warning'),
        Rule.new(:breaks, /RouteAndResourceNamesClashError|MissingRouteAttribute|ProvidedObjectNotAsResponseData|NoConfigurationGivenForEndpoint/,
                 'this error class was removed: nothing raised it, so the rescue clause can go'),
        Rule.new(:breaks, /\.base_configs\b/, 'Api#base_configs was removed: use api.definition', false, :base_configs),
        Rule.new(:breaks, /ApiRecipes::Route\b/, 'ApiRecipes::Route was removed: a request is sent with run'),
        Rule.new(:breaks, /ApiRecipes::Settings\b/,
                 'ApiRecipes::Settings was removed: the defaults are listed in the README'),
        Rule.new(:breaks, /\bconfiguration\.setup\b/,
                 'configuration.setup was removed: configure loads the configuration'),
        Rule.new(:breaks, /ApiRecipes\.print_urls/, 'use config.print_urls inside ApiRecipes.configure', false, :print_urls),
        Rule.new(:breaks, /_aprcps_|set_authorization_for_api|set_basic_auth_for_api|copy_global_authorizations_to_api/,
                 'internal method removed'),
        Rule.new(:breaks, /\bApiRecipes((\.|::)\w+|\[[^\]]*\])\.(authorization|basic_auth)\s*(\|\|)?=(?![=~])/,
                 'a credential of the whole application is given to ApiRecipes.configure, as ' \
                 'config.values = { name: { authorization: ... } }: this writer now raises', false, :global_writer),
        Rule.new(:check, /(?<!\bApiRecipes)\.\w+\.(authorization|basic_auth)\s*(\|\|)?=(?![=~])/,
                 'authorization= and basic_auth= now work on an object only: on a class they raise, ' \
                 'give the credential to `api :name, authorization: ...`, or to with(...) for one request', false, :writer),
        Rule.new(:check, /url_encode|CGI\.escape|encode_www_form_component/,
                 'path parameters are now encoded by ApiRecipes: remove manual encoding of values passed to endpoints', true),
        Rule.new(:check, /\brescue\s*(=>.*)?$|rescue StandardError/,
                 'a bare rescue now catches ApiRecipes errors too', true),
        Rule.new(:check, /\bfollow:/, 'credentials are no longer sent to another origin after a redirect', true),
        Rule.new(:check, /\bresponse\.request\b/,
                 'response.request was removed, because the request holds the credentials: ' \
                 'read response.uri, or response.original_response', true, :request),
        Rule.new(:check, /\.(deep_merge|deep_symbolize_keys|deep_stringify_keys|symbolize_keys|stringify_keys|extract_options!|assert_valid_keys)\b/,
                 'this method came from api_recipes 2.x unless ActiveSupport is loaded: ' \
                 'define it or add ActiveSupport', true)
      ].freeze

      # The rule about the Hash methods that ActiveSupport defines too.
      HASH_METHODS = RULES.last

      # The rule about a rescue that names no class, and what the change
      # that the command offers for it means.
      BARE_RESCUE = RULES.find { |rule| rule.message.start_with?('a bare rescue') }
      RESCUE_NOTE = ['In 2.x this rescue did not catch the errors of api_recipes: they went on to the code that called. ' \
                     'In 3.0 it catches them.',
                     'y: keep what 2.x did. The errors of api_recipes are raised again before this rescue sees them',
                     'n: leave the code as it is. This rescue handles the errors of api_recipes too'].freeze

      # What stands for the value of an ERB tag in a file that is checked
      # without running its code.
      # Options whose value is a mapping: a tag that gives one gives a part
      # of the structure, which is not guessed.
      CONTAINERS = %w[variables endpoints default_headers default_params auth recipe resource].freeze

      # What a line assigns, read without running it, to give the code to paste.
      WRITTEN = '\\s*(?:\\|\\|)?=(?![=~])\\s*(?<code>.+)\\z'
      FIXES = {
        print_urls: /\bApiRecipes\.print_urls#{WRITTEN}/,
        global_writer: /\bApiRecipes(?:(?:\.|::)(?<api>\w+)|\[\s*[:'"](?<api>\w+)['"]?\s*\])\.(?<key>authorization|basic_auth)#{WRITTEN}/,
        writer: /(?<![^\s(=,])(?<receiver>[\w.@:\[\]'"]+)\.(?<api>\w+)\.(?<key>authorization|basic_auth)#{WRITTEN}/,
        base_configs: /(?<![^\s(=,])(?<receiver>[\w.@:\[\]'"]+)\.base_configs\b/,
        route: /\.route\.fill\((?<code>.*)\)/
      }.freeze
      # Code longer than this is not copied into the code to paste.
      MAX_CODE = 300

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
      # code: false leaves out the code to paste, as in a CI whose output is kept.
      def initialize(paths, config: [], erb: false, project: nil, code: true)
        @code = code
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
      def self.for_project(project, erb: false, code: true)
        new(project.ruby_files, config: project.config_files, erb: erb, project: project, code: code)
      end

      def run
        @warnings = @project ? @project.warnings.dup : []
        @notes = []
        @uses = 0
        @startup = []
        @configure = {}
        @direct = {}
        @rescues = []
        findings = with_request_hints(@paths.flat_map { |path| scan_path(path) })
        findings += @configs.flat_map { |file| check_config(file) }
        @notes = scope + @notes if @project
        findings
      end

      # Prints the results on out and the warnings on err. Returns the exit
      # code. What needs an answer comes last, where a terminal stops: what
      # was checked, what the command cannot find, the findings, what to do.
      # input: where the answers come from. On a terminal the command offers
      # the changes it can make by itself, one at a time.
      def report(out, err, input: nil)
        findings = run
        screen = Screen.new(out)
        changed = @code && Fix.asks?(input) ? offered(screen, input) : []
        findings = run unless changed.empty?
        unless @notes.empty?
          screen.section('🔎', 'What was checked', plain: false)
          @notes.each { |note| screen.line(note) }
        end
        screen.section('🙈', 'What this command cannot find', "#{SILENT_CHANGES.size} changes")
        SILENT_CHANGES.each { |change| screen.item(change) }
        unless findings.empty?
          screen.section('📌', 'Findings', plain: false)
          findings.each { |finding| screen.finding(finding.kind, where(finding), finding.message, @code ? finding.hint : nil) }
        end
        pasted = @code && code_to_paste(screen)
        unless changed.empty?
          screen.section('✅', 'Changed in the project')
          changed.each { |file| screen.item("edited #{shown_path(file)}") }
          screen.line('Every change is in `git diff`.')
        end
        @warnings.each { |warning| err.puts warning }
        screen.summary(summary(findings.size), findings.group_by(&:kind).transform_values(&:size)) if findings.any? || @warnings.empty?
        what_to_do(screen, findings, pasted)
        return 1 if findings.any?

        @warnings.empty? ? 0 : 2
      end

      private

      # Offers each change the command can make. The project is read again
      # after a change that was made. Returns the files that were written.
      def offered(screen, input)
        fix = Fix.new(screen, input, shown: method(:shown_path))
        declined = []
        written = []
        while (change = changes.find { |one| !declined.include?(one.key) })
          files = fix.offer(change)
          declined << change.key
          next unless files

          written |= files
          run
        end
        written
      end

      # The changes this command is sure of, in the order they are offered.
      # The rescues of a file come from the last one, so that a change does
      # not move the ones still to offer.
      def changes
        startup_changes + @rescues.sort_by { |item| [item[:file], -item[:line]] }.filter_map { |item| rescue_change(item) }
      end

      # A value that a line gives when the application starts moves into the
      # block of ApiRecipes.configure, when one file has it and it is read whole.
      def startup_changes
        file, text = @configure.size == 1 ? @configure.first : nil
        block = Code::ConfigureBlock.in(text)
        return [] unless block && !block.problem

        urls = @startup.select { |item| item[:api].nil? }
        values = @startup.select { |item| item[:api] }
        found = []
        if urls.size == 1 && !block.assigned_anywhere?(:print_urls)
          found << change(:print_urls, 'Move print_urls into the block of ApiRecipes.configure', urls, file, text, block,
                          ["#{block.config}.print_urls = #{urls.first[:code]}"])
        end
        unless values.empty? || block.assigned_anywhere?(:values)
          found << change(:values, 'Give the credentials of the application to ApiRecipes.configure, as config.values', values, file, text,
                          block, ["#{block.config}.values = {", *entries_of(values).map { |entry| "  #{entry}" }, '}'])
        end
        found.compact
      end

      # A rescue that names no class gets, before it, a rescue of the errors
      # of the gem that raises them again: what 2.x did. nil for a rescue
      # that does not start a line of its own, as in `x rescue y`.
      def rescue_change(item)
        text = read_ruby(item[:file])
        tree = text && Code.tree(text)
        clause = tree && rescue_at(tree, item[:line])&.last
        line = text && text.lines[item[:line] - 1]
        return nil unless clause && line.match?(/\A[ \t]*rescue\b/)
        return nil unless clause.exceptions.empty? || clause.exceptions.any? { |one| one.slice.delete_prefix('::') == 'StandardError' }

        indent = line[/\A[ \t]*/]
        written = text.lines.insert(item[:line] - 1, "#{indent}rescue ApiRecipes::Error\n", "#{indent}  raise\n").join
        return nil unless gem_errors_handled?(written, item[:line] + 2)

        # Counted from the end of the file, the place of a rescue stays the
        # same when a change is made above it.
        Fix::Change.new([:rescue, item[:file], text.lines.size - item[:line]],
                        "Keep the errors of ApiRecipes out of the rescue at #{shown_path(item[:file])}:#{item[:line]}, as in 2.x",
                        { item[:file] => written }, RESCUE_NOTE)
      end

      # The rescue clause that starts at line number, after the clauses of
      # the same begin that come before it: [[earlier clauses], clause].
      def rescue_at(tree, number)
        Code.nodes(tree) { |node| node.is_a?(Prism::BeginNode) && node.rescue_clause }.each do |owner|
          earlier = []
          clause = owner.rescue_clause
          while clause
            return [earlier, clause] if clause.location.start_line == number

            earlier << clause
            clause = clause.compact_child_nodes.find { |child| child.is_a?(Prism::RescueNode) }
          end
        end
        nil
      end

      # Whether a clause before the one at line number rescues ApiRecipes::Error.
      def gem_errors_handled?(text, number)
        tree = Code.tree(text)
        earlier = tree && rescue_at(tree, number)&.first
        return false unless earlier

        earlier.any? { |clause| clause.exceptions.any? { |one| one.slice.delete_prefix('::') == 'ApiRecipes::Error' } }
      end

      # The texts of the files after the lines of items are taken out and
      # added is written at the end of the block. nil when a line is not a
      # whole statement of its own, or when a result is not valid Ruby.
      def change(key, title, items, file, text, block, added)
        texts = items.group_by { |item| item[:file] }.to_h { |path, list| [path, [path == file ? text : read_ruby(path), list.map { |item| item[:line] }]] }
        texts[file] ||= [text, []]
        return nil unless texts.all? { |_, (content, lines)| content && lines.all? { |number| own_statement?(content, number) } }

        written = texts.to_h do |path, (content, lines)|
          kept = content.lines.each_with_index.reject { |_, index| lines.include?(index + 1) }
          next [path, kept.map(&:first).join] unless path == file

          inside = lines.select { |number| number.between?(block.first, block.last) }
          now = block.lines(added, without: inside).map { |line| "#{line}\n" }
          [path, kept.flat_map { |line, index| index + 1 == block.first ? now : (index + 1).between?(block.first, block.last) ? [] : [line] }.join]
        end
        written.values.all? { |content| Code.tree(content) } ? Fix::Change.new(key, title, written) : nil
      end

      # Whether line number of text holds one whole statement and nothing else.
      def own_statement?(text, number)
        tree = Code.tree(text)
        return false unless tree

        statements = Code.nodes(tree) { |node| node.is_a?(Prism::StatementsNode) }.flat_map(&:body)
        here = statements.select { |node| node.location.start_line == number && node.location.end_line == number }
        here.size == 1 && text.lines[number - 1].strip == here.first.slice
      end

      def entries_of(items)
        entries = items.group_by { |item| item[:api] }.map do |api, list|
          "#{api.match?(/\A[a-z_]\w*\z/) ? api : "\"#{api}\""}: { #{list.map { |item| "#{item[:key]}: #{item[:code]}" }.join(', ')} }"
        end
        entries.each_with_index.map { |entry, index| index == entries.size - 1 ? entry : "#{entry}," }
      end

      # What the person does with the results, in order.
      def what_to_do(screen, findings, pasted)
        counts = findings.group_by(&:kind).transform_values(&:size)
        lines = ->(count) { "#{count} line#{'s' unless count == 1}" }
        steps = []
        steps << "Fix the #{lines.call(counts[:breaks])} marked breaks: that code stops working, and each line says what to use instead#{'. The code to paste, above, does it for the values given when the application starts' if pasted}" if counts[:breaks]
        steps << "Correct what is marked config (#{counts[:config]}): each is a problem in a file that describes an api" if counts[:config]
        steps << "Read the #{lines.call(counts[:check])} marked check: the result changes, and only you can tell whether the code still does what it should. A check line is reported at every run" if counts[:check]
        steps << 'Go through what this command cannot find: look in the code for the changes that concern the project'
        steps << 'Run this command again: go on when only check lines that you have read are left' if counts[:breaks] || counts[:config]
        steps << 'Start the application and run its tests: ApiRecipes.configure checks the whole configuration when it loads, also what an ERB tag gives, and lists every problem at once'
        screen.section('👉', 'What to do now')
        steps.each_with_index { |step, index| screen.item(step, "#{index + 1}.") }
      end

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

      def where(finding)
        file = shown_path(finding.file)
        finding.line ? "#{file}:#{finding.line}" : file
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
        @configure[file] = text if text.match?(/\bApiRecipes\.configure\b/)
        found = []
        text.each_line(chomp: true).with_index(1) do |line, number|
          rules.each do |rule|
            next unless rule.pattern.match?(line)

            if rule.equal?(BARE_RESCUE)
              # A rescue that comes after one of ApiRecipes::Error never sees them.
              next if gem_errors_handled?(text, number)

              @rescues << { file: file, line: number }
            end
            found << Finding.new(file: file, line: number, kind: rule.kind, message: rule.message, hint: hint(rule.fix, line, file, number, text))
          end
        end
        found
      end

      # ---- the code to paste ----

      # The code a line assigns, when it can be copied: on one line, short,
      # and with nothing a terminal would obey.
      def code_of(match)
        code = without_comment(match[:code].to_s.strip)
        return nil if code.empty? || code.length > MAX_CODE || Code::UNSAFE.match?(code) || !expression?(code)

        code
      end

      # code up to a comment that follows it on the line.
      def without_comment(code)
        quote = nil
        code.each_char.with_index do |char, index|
          if quote
            quote = nil if char == quote && code[index - 1] != '\\'
          elsif ["'", '"', '`'].include?(char)
            quote = char
          elsif char == '#' && (index.zero? || code[index - 1].match?(/\s/))
            return code[0...index].rstrip
          end
        end
        code
      end

      # Whether code is one whole Ruby expression, and not one that a word
      # after it changes (if, unless, rescue, and, or). It is read, never run.
      def expression?(code)
        tree = Code.tree(code)
        return false unless tree && tree.statements.body.size == 1

        node = tree.statements.body.first
        return false if [Prism::IfNode, Prism::UnlessNode, Prism::RescueModifierNode, Prism::WhileNode, Prism::UntilNode].any? { |kind| node.is_a?(kind) }

        !((node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode)) && %w[and or].include?(node.operator_loc.slice))
      end

      # Whether the statement on line is always run when its file is: a
      # statement of the file itself, or of the block of ApiRecipes.configure,
      # not one inside a condition or another block.
      def always_run?(file, text, line)
        @direct ||= {}
        @direct[file] ||= begin
          tree = Code.tree(text)
          top = tree ? tree.statements.body.map { |node| node.location.start_line } : []
          block = Code::ConfigureBlock.in(text)
          top + (block ? block.statement_lines : [])
        end
        @direct[file].include?(line)
      end

      # The lines shown under a finding. A value given when the application
      # starts is kept aside: all of them go in one block of configure.
      def hint(fix, line, file, number, text)
        match = FIXES[fix]&.match(line)
        case fix
        when :request then ['response.uri                # the address of the request', 'response.original_response  # the http.rb response']
        when :base_configs then match && !Code::UNSAFE.match?(match[:receiver]) ? ["#{match[:receiver]}.definition"] : nil
        when :route then (code = match && code_of(match)) ? ["response.fill(#{code})  # response is what run returned"] : nil
        when :writer
          code = match && code_of(match)
          return nil unless code && !Code::UNSAFE.match?(match[:receiver])

          ['# for a class, where it declares the api:', "api :#{match[:api]}, #{match[:key]}: #{code}", '# for one request:',
           "#{match[:receiver]}.#{match[:api]}.with(#{match[:key]}: #{code})"]
        when :print_urls, :global_writer
          code = match && code_of(match)
          return nil unless code && always_run?(file, text, number)

          @startup << { file: file, line: number, api: fix == :print_urls ? nil : match[:api], key: fix == :print_urls ? 'print_urls' : match[:key], code: code }
          nil
        end
      end

      # A credential of the application assigned in more than one place is
      # assigned for each request: each of those lines becomes a with.
      def with_request_hints(findings)
        repeated = @startup.group_by { |item| [item[:api], item[:key]] }.select { |(api, _), items| api && items.size > 1 }.values.flatten
        @startup -= repeated
        findings.map do |finding|
          item = repeated.find { |one| one[:file] == finding.file && one[:line] == finding.line }
          next finding unless item && finding.hint.nil? && FIXES[:global_writer].match?('ApiRecipes.x.' + item[:key] + ' = 1') && finding.message.include?('config.values')

          finding.with(hint: ["ApiRecipes.#{item[:api]}.with(#{item[:key]}: #{item[:code]})  # use the api it returns for the calls of this request"])
        end
      end

      # The values given when the application starts, in the block of
      # ApiRecipes.configure: the whole block when one file has it.
      def code_to_paste(screen)
        return false if @startup.empty?

        file, text = @configure.size == 1 ? @configure.first : nil
        block = Code::ConfigureBlock.in(text)
        block = nil if block&.problem
        config = block ? block.config : 'config'
        inside = @startup.select { |item| block && item[:file] == file && item[:line].between?(block.first, block.last) }
        added = @startup.select { |item| item[:api].nil? }.first(1).map { |item| "#{config}.print_urls = #{item[:code]}" }
        added = [] if block&.line_of(:print_urls)
        entries = entries_of(@startup.select { |item| item[:api] })
        merged = block && block.line_of(:values)
        added += ["#{config}.values = {", *entries.map { |entry| "  #{entry}" }, '}'] unless entries.empty? || merged

        screen.section('📋', 'Code to paste')
        screen.gap
        if block
          screen.line("In #{shown_path(file)}, replace the block of ApiRecipes.configure (lines #{block.first} to #{block.last}) with:")
          screen.code(block.lines(added, without: inside.map { |item| item[:line] }))
        else
          screen.line('Inside the block of ApiRecipes.configure:')
          screen.code(added)
        end
        if merged && !entries.empty?
          screen.line("and add to the Hash that #{config}.values is given at line #{merged}:")
          screen.code(entries)
        end
        outside = (@startup - inside).map { |item| "#{shown_path(item[:file])}:#{item[:line]}" }
        screen.line("Then remove the lines that gave these values: #{outside.join(', ')}") unless outside.empty?
        true
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
        plain = Tags.replaced(text, @erb_value)
        return plain if plain

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
