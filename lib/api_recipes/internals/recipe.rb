# frozen_string_literal: true

require 'digest'

module ApiRecipes
  module Internals
    # A portable recipe: a file with one api that is only data, written by
    # someone else. It is never evaluated with ERB, it is read as plain YAML,
    # and it must say its name and its version under the key `recipe`.
    class Recipe
      MAX_BYTES = 1_048_576
      SUFFIX = '.recipe.yml'
      FORMAT = 1
      NAME = /\A[a-z0-9_][a-z0-9_-]{0,63}\z/
      VERSION = /\A[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*\z/
      MAX_VERSION = 32
      KEYS = %w[name version format summary homepage].freeze
      HOMEPAGE = %r{\Ahttps?://[!-~]+\z}
      MAX_TEXT = 200
      WHOLE_HOST = /\A\{[A-Za-z_]\w*\}\z/
      FIXED_END = /\A\.[A-Za-z0-9]/

      class << self
        # The recipe in the file at path. Raises RecipeFileError, which names
        # the file. With compile: false the rules of the gem for an api are
        # left to whoever compiles the result.
        def read(path, compile: true)
          text, file_name = read_text(path)
          new(text, path, file_name: file_name, compile: compile)
        end

        # The recipe written in text. where names it in the errors.
        def parse(text, where, file_name: nil, compile: true)
          new(text, where, file_name: file_name, compile: compile)
        end

        # The apis of the files, as { name => options }. Each file must be in
        # the recipes.lock of its folder with the checksum it has now, and is
        # not parsed otherwise. taken: the names that other sources define.
        # Every problem is reported, in one ConfigurationError.
        def load_all(paths, taken: [])
          errors = []
          locks = {}
          apis = {}
          paths.each do |path|
            recipe = load_one(path, locks)
            name = recipe.apis.keys.first
            if taken.include?(name)
              raise RecipeFileError.new(path, "the api '#{name}' is already defined by apis_configs or apis_files_paths: " \
                                              'a recipe never takes the place of an api')
            end
            raise RecipeFileError.new(path, "the api '#{name}' is already given by another recipe file") if apis.key?(name)

            apis.merge!(recipe.apis)
          rescue ConfigurationError => e
            errors.concat(e.errors)
          end
          raise ConfigurationError.new(errors) unless errors.empty?

          apis
        end

        def digest(text) = Digest::SHA256.hexdigest(text)

        # The text of the file at path and the name of the file. The text is
        # read as bytes and tagged as UTF-8; no more than the limit is read.
        def read_text(path)
          unless (path.is_a?(String) || path.is_a?(Pathname)) && !path.to_s.include?("\0")
            raise ConfigurationError.new(['recipes_paths: every path must be a String or a Pathname, without null bytes'])
          end

          full = File.expand_path(path)
          file_name = File.basename(full)
          unless file_name.end_with?(SUFFIX)
            raise RecipeFileError.new(path, "is not called NAME#{SUFFIX}: only portable recipes go in recipes_paths")
          end
          raise RecipeFileError.new(path, 'file not found') unless File.exist?(full)
          raise RecipeFileError.new(path, 'is not a file') unless File.file?(full)

          text = File.open(full, 'rb') { |file| file.read(MAX_BYTES + 1) } || +''
          raise RecipeFileError.new(path, "is larger than #{MAX_BYTES} bytes") if text.bytesize > MAX_BYTES

          [text.force_encoding(Encoding::UTF_8), file_name]
        rescue SystemCallError => e
          raise RecipeFileError.new(path, "cannot read file (#{e.class.name.split('::').last})")
        end

        private

        def load_one(path, locks)
          text, file_name = read_text(path)
          directory = File.dirname(File.expand_path(path))
          lock = locks[directory] ||= RecipeLock.read(directory)
          problem = lock.problem_for(file_name.delete_suffix(SUFFIX), digest(text))
          raise RecipeFileError.new(path, "#{problem} `api_recipes install #{path}`") if problem

          new(text, path, file_name: file_name, compile: false)
        end
      end

      # name and version are text; apis is { name => options } as the compiler
      # takes it; definition is the compiled api, or nil with compile: false.
      attr_reader :name, :version, :apis, :definition, :text, :sha256

      def initialize(text, where, file_name: nil, compile: true)
        @where = where
        @text = text
        @sha256 = self.class.digest(text)
        refuse('contains <%: a recipe is never evaluated with ERB, and must not hold text that ERB would run') if text.include?('<%')
        name, options = one_api(plain_data(text))
        problems = name_problems(name, file_name) + recipe_problems(name, options['recipe']) +
                   verify_with_problems(name, options) + host_problems(options['host'])
        refuse(problems) unless problems.empty?

        @name = name
        @version = options['recipe']['version']
        @apis = compiled { Compiler.normalize({ name => options }, :options_map) }
        @definition = compiled { Compiler.compile_all(@apis).values.first } if compile
        freeze
      end

      private

      def refuse(reasons) = raise(RecipeFileError.new(@where, reasons))

      def compiled
        yield
      rescue ConfigurationError => e
        refuse(e.errors)
      end

      def plain_data(text)
        PlainYaml.load(text, max_bytes: MAX_BYTES)
      rescue PlainYaml::Refused => e
        refuse(e.message)
      end

      def one_api(data)
        refuse('file is empty') if data.nil?
        refuse('must contain one api: a mapping from its name to its options') unless data.is_a?(Hash)
        unless data.size == 1
          refuse("must contain one api, but it has #{data.size}: #{data.keys.first(5).map { |key| PlainYaml.label(key) }.join(', ')}")
        end
        name, options = data.first
        refuse("the api '#{PlainYaml.label(name)}' must be a mapping of options") unless options.is_a?(Hash)

        [name, options]
      end

      def name_problems(name, file_name)
        unless NAME.match?(name)
          return ["the api name '#{PlainYaml.label(name)}' must be made of lowercase letters, digits, - and _, " \
                  'at most 64, and must not start with -']
        end
        return [] if file_name.nil? || file_name == "#{name}#{SUFFIX}"

        ["the file must be called #{name}#{SUFFIX}, after its api"]
      end

      def recipe_problems(name, recipe)
        return ['the key recipe is required, with name and version'] unless recipe.is_a?(Hash)

        problems = (recipe.keys - KEYS).reject { |key| Compiler::IGNORED_KEY.match?(key) }.map do |key|
          "recipe: unknown key '#{PlainYaml.label(key)}'"
        end
        problems << "recipe.name must be '#{name}', the name of the api" unless recipe['name'] == name
        problems.concat(version_problems(recipe['version']))
        unless recipe['format'].nil? || recipe['format'] == FORMAT
          problems << "recipe.format #{PlainYaml.label(recipe['format'])} is not known to this version of api_recipes " \
                      "(it knows #{FORMAT}): update the gem"
        end
        problems << "recipe.summary must be one line of text, at most #{MAX_TEXT} characters" unless line?(recipe['summary'])
        homepage = recipe['homepage']
        unless homepage.nil? || (homepage.is_a?(String) && homepage.length <= MAX_TEXT && HOMEPAGE.match?(homepage))
          problems << 'recipe.homepage must be an http or https address, without spaces'
        end
        problems
      end

      def version_problems(version)
        return ['recipe.version is required'] if version.nil?
        return ['recipe.version must be text: write it between quotes'] unless version.is_a?(String)
        return [] if version.length <= MAX_VERSION && VERSION.match?(version)

        ["recipe.version must be made of digits, letters and dots, at most #{MAX_VERSION} characters"]
      end

      def line?(value)
        value.nil? || (value.is_a?(String) && value.length <= MAX_TEXT && !value.match?(PlainYaml::UNPRINTABLE))
      end

      # verify_with names a method of the application: a recipe cannot ask for it.
      def verify_with_problems(name, options, location = '')
        problems = []
        if options.key?('verify_with')
          problems << "#{location}verify_with is not allowed in a recipe: add it in your code, with " \
                      "`api :#{name}, verify_with: ...`"
        end
        endpoints = options['endpoints']
        return problems unless endpoints.is_a?(Hash)

        endpoints.each do |child, child_options|
          next unless child_options.is_a?(Hash)

          problems.concat(verify_with_problems(name, child_options, "#{location}endpoints.#{PlainYaml.label(child)}."))
        end
        problems
      end

      # A variable can be the whole host, or stand before fixed text that
      # starts with a dot: its value never decides where the host ends.
      def host_problems(host)
        return ['host is required'] if host.nil?
        return [] unless host.is_a?(String) && host.match?(Template::VARIABLE)
        return [] if WHOLE_HOST.match?(host) || FIXED_END.match?(host.rpartition(Template::VARIABLE).last)

        ["host: a variable must be the whole host or stand before fixed text that starts with a dot, as in " \
         "'{shop}.example.com': here a variable would decide where the host ends"]
      end
    end
  end
end
