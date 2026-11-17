# frozen_string_literal: true

module ApiRecipes
  module CLI
    class Upgrade
      # The project in a directory, as `api_recipes upgrade` without arguments
      # sees it: its Ruby files, the files that describe an api and the names
      # of its apis. It reads files and never runs one.
      class Project
        # Top-level folders that hold no code of the project.
        SKIPPED = %w[vendor node_modules tmp log coverage public storage].freeze
        RUBY = /\.(rb|rake)\z/
        YAML_FILE = /\.(yml|yaml)(\.erb)?\z/
        # A description of an api has endpoints, as a key below its name.
        DESCRIBES_AN_API = /^[ \t]+endpoints:[ \t]*(#.*)?$/
        TOP_LEVEL_NAME = /^([A-Za-z_][A-Za-z0-9_]*):/
        DECLARATION = /\bapi[ \t(]+:([A-Za-z_][A-Za-z0-9_]*)(?:.*?\bas:[ \t]*:([A-Za-z_][A-Za-z0-9_]*))?/
        # A file larger than this is not a description of an api.
        LARGEST = 2 * 1024 * 1024

        Declared = Data.define(:file, :line, :name)

        # Paths relative to root, sorted. warnings: what could not be read.
        attr_reader :ruby_files, :config_files, :warnings

        def initialize(root = '.')
          @root = root
          @ruby_files = []
          @config_files = []
          @warnings = []
          @texts = {}
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

        # The names an api is called by: the names in the configuration files
        # and those given to `api` in the code, with `as:` when there is one.
        def api_names
          @api_names ||= (described + declarations.map(&:name)).uniq.sort
        end

        # The apis the files of the project describe.
        def described
          @described ||= @config_files.flat_map { |file| text(file).to_s.scan(TOP_LEVEL_NAME).flatten }.uniq
        end

        # Where the code declares an api: `api :name`.
        def declarations
          @declarations ||= @ruby_files.flat_map do |file|
            found = []
            text(file).to_s.each_line.with_index(1) do |line, number|
              match = DECLARATION.match(line)
              found << Declared.new(file: file, line: number, name: match[2] || match[1]) if match
            end
            found
          end
        end

        # The declarations of an api that no file found here describes.
        def undescribed
          return [] if @ruby_files.any? { |file| text(file).to_s.include?('apis_configs') }

          declarations.reject do |declared|
            line = text(declared.file).to_s.lines[declared.line - 1].to_s
            match = DECLARATION.match(line)
            described.include?(match[1]) || line.match?(/\b(endpoints|host):/)
          end
        end

        # Whether the text of a Ruby file names the gem or calls one of the apis.
        def uses_gem?(text)
          return true if text.match?(/\bApiRecipes\b/)

          names = api_names
          !names.empty? && text.match?(/\b(?:#{names.map { |name| Regexp.escape(name) }.join('|')})\b[ \t]*[.\[]/)
        end

        private

        def walk(directory)
          entries = Dir.children(directory ? File.join(@root, directory) : @root).sort
          entries.each do |name|
            next if name.start_with?('.')
            next if directory.nil? && SKIPPED.include?(name)

            relative = directory ? File.join(directory, name) : name
            full = File.join(@root, relative)
            if File.directory?(full)
              walk(relative) unless File.symlink?(full)
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
          elsif YAML_FILE.match?(name) && text(relative)&.match?(DESCRIBES_AN_API)
            @config_files << relative
          end
        end

        def read(file)
          full = File.join(@root, file)
          return nil if File.size(full) > LARGEST

          bytes = File.binread(full)
          return nil if bytes.include?("\0")

          text = bytes.force_encoding(Encoding::UTF_8)
          text.valid_encoding? ? text : nil
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
