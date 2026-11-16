# frozen_string_literal: true

require 'api_recipes/cli/recipes/summary'

module ApiRecipes
  module CLI
    # The commands for portable recipes: check, install and update.
    class Recipes
      DEFAULT_DIRECTORY = 'config/api_recipes'
      Recipe = Internals::Recipe
      RecipeLock = Internals::RecipeLock

      def initialize(out:, err:, input: nil)
        @out = out
        @err = err
        @input = input
      end

      # Validates each file as a portable recipe. Without files, compares the
      # recipes of directory with its recipes.lock, as configure does. Returns
      # the exit code: 2 if something could not be read, else 1 if something is
      # not valid or does not match, else 0.
      def check(files, directory: DEFAULT_DIRECTORY)
        return check_directory(directory) if files.empty?

        files.map { |file| check_file(file) }.max
      end

      private

      def check_file(file)
        unless File.file?(file) && File.readable?(file)
          @err.puts "#{file}: #{File.file?(file) ? 'cannot be read' : (File.exist?(file) ? 'is not a file' : 'no such file')}"
          return 2
        end

        describe(file, Recipe.read(file))
        0
      rescue ConfigurationError => e
        e.errors.each { |problem| @err.puts problem }
        1
      end

      def describe(file, recipe)
        summary = Summary.new(recipe)
        calls = recipe.definition.routes.size
        @out.puts "#{file}: #{summary.title}, #{calls} call#{'s' unless calls == 1}"
        summary.warnings.each { |warning| @err.puts "#{file}: warning: #{warning}" }
      end

      def check_directory(directory)
        unless File.directory?(directory)
          @err.puts "#{directory}: no such folder"
          return 2
        end

        lock = RecipeLock.read(directory)
        names = Dir.children(directory).select { |name| name.end_with?(Recipe::SUFFIX) }.sort
        codes = names.map { |name| check_installed(File.join(directory, name), name.delete_suffix(Recipe::SUFFIX), lock) }
        (lock.entries.keys - names.map { |name| name.delete_suffix(Recipe::SUFFIX) }).sort.each do |name|
          @err.puts "#{lock.path}: #{name} is in the lock, but #{File.join(directory, "#{name}#{Recipe::SUFFIX}")} is missing"
          codes << 1
        end
        @out.puts "no recipes in #{directory}" if codes.empty?
        codes.max || 0
      rescue ConfigurationError => e
        e.errors.each { |problem| @err.puts problem }
        1
      rescue SystemCallError => e
        @err.puts "#{directory}: cannot be read (#{e.class.name.split('::').last})"
        2
      end

      def check_installed(file, name, lock)
        text, = Recipe.read_text(file)
        problem = lock.problem_for(name, Recipe.digest(text))
        if problem
          @err.puts "#{file}: #{problem} `api_recipes install #{file}`"
          return 1
        end

        recipe = Recipe.parse(text, file, file_name: File.basename(file))
        describe(file, recipe)
        return 0 if lock[name].version == recipe.version

        @err.puts "#{lock.path}: #{name} is version #{lock[name].version} in the lock, but the file says #{recipe.version}"
        1
      rescue ConfigurationError => e
        e.errors.each { |one| @err.puts one }
        1
      end
    end
  end
end
