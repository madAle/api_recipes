# frozen_string_literal: true

require 'yaml'

module ApiRecipes
  module CLI
    class Upgrade
      # The project in a directory, as `api_recipes upgrade` without arguments
      # sees it: its Ruby files, the files that describe an api and the names
      # of its apis. It reads files and never runs one, and it does not follow
      # a symbolic link.
      class Project
        # Top-level folders that hold no code of the project.
        SKIPPED = %w[vendor node_modules tmp log coverage public storage].freeze
        # Folders skipped wherever they are.
        SKIPPED_ANYWHERE = %w[node_modules].freeze
        # Top-level folders whose YAML files are fixtures, not the configuration.
        NO_CONFIGURATION = %w[spec test features].freeze
        RUBY = /\.(rb|rake)\z/
        YAML_FILE = /\.(yml|yaml)(\.erb)?\z/
        # The line of a file that ERB shapes, which cannot be parsed: enough
        # to report it.
        ENDPOINTS_LINE = /^[ \t]+endpoints:[ \t]*(#.*)?$/
        DECLARATION = /^[ \t]*api[ \t(]+:([A-Za-z_]\w*)(?:.*?\bas:[ \t]*[:'"]([A-Za-z_]\w*))?/
        # A file larger than this is not a description of an api.
        LARGEST = 2 * 1024 * 1024
        # More values than a description holds: aliases make them from a few lines.
        MAX_VALUES = 200_000

        # api: the name given to `api`; method: the name it is called by.
        Declared = Data.define(:file, :line, :api, :method)

        # Paths relative to root, sorted. warnings: what could not be read.
        attr_reader :ruby_files, :config_files, :warnings

        # Whether data holds no more than limit values, aliases counted each
        # time they are used. It stops as soon as the limit is passed.
        def self.within?(data, limit, seen = [0])
          seen[0] += 1
          return false if seen[0] > limit

          case data
          when Hash then data.all? { |key, inner| within?(key, limit, seen) && within?(inner, limit, seen) }
          when Array then data.all? { |inner| within?(inner, limit, seen) }
          else true
          end
        end

        def initialize(root = '.')
          @root = root
          @ruby_files = []
          @config_files = []
          @warnings = []
          @texts = {}
          @described = []
          walk(nil)
        end

        # Rails and most applications load ActiveSupport, which defines the
        # Hash methods that api_recipes 2.x also added.
        def active_support?
          lock = File.join(@root, 'Gemfile.lock')
          File.file?(lock) && File.foreach(lock).any? { |line| line.match?(/\A\s+activesupport \(/) }
        rescue SystemCallError, ArgumentError
          false
        end

        # The text of a file of the project, or nil when it is not text.
        def text(file)
          return @texts[file] if @texts.key?(file)

          @texts[file] = read(file)
        end

        # The names an api is called by: those the files describe, and those
        # given to `api` in the code, with `as:` when there is one.
        def api_names
          @api_names ||= (described + declarations.map(&:method)).uniq.sort
        end

        # The apis the files of the project describe.
        def described = @described.uniq

        # Where the code declares an api: a line that starts with `api :name`.
        def declarations
          @declarations ||= @ruby_files.flat_map do |file|
            found = []
            text(file).to_s.each_line.with_index(1) do |line, number|
              match = DECLARATION.match(line)
              found << Declared.new(file: file, line: number, api: match[1], method: match[2] || match[1]) if match
            end
            found
          end
        end

        # The declarations of an api that no file found here describes, and
        # that do not describe it themselves.
        def undescribed
          return [] if @ruby_files.any? { |file| text(file).to_s.include?('apis_configs') }

          declarations.reject do |declared|
            described.include?(declared.api) || text(declared.file).to_s.lines[declared.line - 1].to_s.match?(/\b(endpoints|host):/)
          end
        end

        # Whether the code of a Ruby file names the gem or calls one of the
        # apis. Comment lines are not code.
        def uses_gem?(text)
          code = text.each_line.reject { |line| line.lstrip.start_with?('#') }.join
          return true if code.match?(/\bApiRecipes\b/)

          names = api_names
          !names.empty? && code.match?(%r{(?<![\w/])(?:#{names.map { |name| Regexp.escape(name) }.join('|')})\b[ \t]*(?:\.[a-z_]|\[)})
        end

        private

        def walk(directory)
          entries = Dir.children(directory ? File.join(@root, directory) : @root).sort
          entries.each do |name|
            next if name.start_with?('.') || SKIPPED_ANYWHERE.include?(name)
            next if directory.nil? && SKIPPED.include?(name)

            relative = directory ? File.join(directory, name) : name
            full = File.join(@root, relative)
            next if File.symlink?(full)

            if File.directory?(full)
              walk(relative)
            elsif File.file?(full)
              keep(relative, name)
            end
          end
        rescue SystemCallError => e
          @warnings << "#{directory || @root}: cannot read (#{e.class.name.split('::').last})"
        end

        def keep(relative, name)
          if RUBY.match?(name)
            @ruby_files << relative
          elsif name.end_with?(Internals::Recipe::SUFFIX)
            @config_files << relative
            @described.concat(apis_in(text(relative)) || [])
          elsif YAML_FILE.match?(name) && !NO_CONFIGURATION.include?(relative.split('/').first)
            names = apis_in(text(relative))
            return if names.nil?

            @config_files << relative
            @described.concat(names)
          end
        end

        # The names of the apis that text describes, or nil when it describes
        # none. An api is a name with endpoints, each with its options or with
        # none. Tags are read as a word, never run.
        def apis_in(text)
          return nil if text.nil? || !text.include?('endpoints')

          plain = text.gsub(/<%#.*?%>/m, '').gsub(/<%=.*?%>/m, 'erb')
          return (ENDPOINTS_LINE.match?(text) ? [] : nil) if plain.gsub('<%%', '').include?('<%')

          data = YAML.safe_load(plain, permitted_classes: [Symbol], aliases: true)
          return nil unless data.is_a?(Hash) && self.class.within?(data, MAX_VALUES)

          names = data.select { |_, options| api?(options) }.keys.map(&:to_s)
          names.empty? ? nil : names
        rescue Psych::Exception, SystemStackError
          ENDPOINTS_LINE.match?(text) ? [] : nil
        end

        def api?(options)
          return false unless options.is_a?(Hash)

          endpoints = options['endpoints'] || options[:endpoints]
          endpoints.is_a?(Hash) && endpoints.values.all? { |one| one.nil? || one.is_a?(Hash) }
        end

        def read(file)
          full = File.join(@root, file)
          return nil if File.size(full) > LARGEST

          bytes = File.binread(full)
          return nil if bytes.include?("\0")

          text = bytes.force_encoding(Encoding::UTF_8)
          text.valid_encoding? ? text : nil
        rescue SystemCallError => e
          @warnings << "#{file}: cannot read (#{e.class.name.split('::').last})"
          nil
        end
      end
    end
  end
end
