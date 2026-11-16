# frozen_string_literal: true

module ApiRecipes
  module Internals
    # The recipes.lock of a folder: for each installed recipe its version,
    # where it came from and the checksum of its file. It is written by the
    # api_recipes command and only read here.
    class RecipeLock
      FILE_NAME = 'recipes.lock'
      FORMAT = 1
      KEYS = %w[format recipes].freeze
      ENTRY_KEYS = %w[version source commit sha256].freeze
      SHA256 = /\A[0-9a-f]{64}\z/
      COMMIT = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
      SOURCE = /\A[!-~]{1,2000}\z/

      Entry = Data.define(:version, :source, :commit, :sha256)

      class << self
        # The lock of the folder; an empty one when the folder has none.
        def read(directory)
          path = File.join(directory, FILE_NAME)
          return new(path, {}, false) unless File.exist?(path)
          raise RecipeFileError.new(path, 'is not a file') unless File.file?(path)

          text = File.open(path, 'rb') { |file| file.read(Recipe::MAX_BYTES + 1) } || +''
          raise RecipeFileError.new(path, "is larger than #{Recipe::MAX_BYTES} bytes") if text.bytesize > Recipe::MAX_BYTES

          new(path, entries(path, text.force_encoding(Encoding::UTF_8)), true)
        rescue SystemCallError => e
          raise RecipeFileError.new(path, "cannot read file (#{e.class.name.split('::').last})")
        end

        private

        def entries(path, text)
          data = PlainYaml.load(text, max_bytes: Recipe::MAX_BYTES)
          problems = problems_of(data)
          raise RecipeFileError.new(path, problems) unless problems.empty?

          (data['recipes'] || {}).to_h do |name, entry|
            [name, Entry.new(version: entry['version'], source: entry['source'], commit: entry['commit'],
                             sha256: entry['sha256'])]
          end
        rescue PlainYaml::Refused => e
          raise RecipeFileError.new(path, e.message)
        end

        def problems_of(data)
          return ['must be a mapping with format and recipes'] unless data.is_a?(Hash)

          problems = (data.keys - KEYS).map { |key| "unknown key '#{PlainYaml.label(key)}'" }
          unless data['format'] == FORMAT
            problems << "format #{PlainYaml.label(data['format'])} is not known to this version of api_recipes " \
                        "(it knows #{FORMAT}): update the gem"
          end
          recipes = data['recipes']
          return problems if recipes.nil?
          return problems << 'recipes must be a mapping' unless recipes.is_a?(Hash)

          recipes.each { |name, entry| problems.concat(entry_problems(name, entry)) }
          problems
        end

        def entry_problems(name, entry)
          shown = PlainYaml.label(name)
          return ["recipes: '#{shown}' is not the name of a recipe"] unless Recipe::NAME.match?(name)
          return ["recipes.#{shown} must be a mapping"] unless entry.is_a?(Hash)

          problems = (entry.keys - ENTRY_KEYS).map { |key| "recipes.#{shown}: unknown key '#{PlainYaml.label(key)}'" }
          version = entry['version']
          unless version.is_a?(String) && version.length <= Recipe::MAX_VERSION && Recipe::VERSION.match?(version)
            problems << "recipes.#{shown}.version must be the version of the recipe, as text"
          end
          problems << "recipes.#{shown}.sha256 must be a SHA-256 checksum" unless text?(entry['sha256'], SHA256)
          source = entry['source']
          commit = entry['commit']
          problems << "recipes.#{shown}.source must be an address without spaces" unless source.nil? || text?(source, SOURCE)
          problems << "recipes.#{shown}.commit must be the id of a commit" unless commit.nil? || text?(commit, COMMIT)
          problems << "recipes.#{shown}: source and commit go together" unless source.nil? == commit.nil?
          problems
        end

        def text?(value, pattern) = value.is_a?(String) && pattern.match?(value)
      end

      attr_reader :path, :entries

      def initialize(path, entries, exists)
        @path = path
        @entries = entries.freeze
        @exists = exists
        freeze
      end

      def exists? = @exists

      def [](name) = @entries[name]

      # Why the file of the recipe called name, with this checksum, is not
      # what was installed; nil when it is. The sentence ends where the
      # command that settles it goes.
      def problem_for(name, sha256)
        entry = @entries[name]
        if entry.nil?
          missing = exists? ? '' : " (there is no #{FILE_NAME} in its folder)"
          return "is not in #{FILE_NAME}#{missing}: a recipe is loaded only after it was installed. Install it with"
        end
        return nil if entry.sha256 == sha256

        "was changed after it was installed: its checksum is not the one in #{FILE_NAME}. To accept the file as it is now, run"
      end
    end
  end
end
