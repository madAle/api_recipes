# frozen_string_literal: true

module ApiRecipes
  module CLI
    # The routes command: the calls that the recipes in some files offer, one
    # per line, with the verb and the address. A file called NAME.recipe.yml is
    # a portable recipe, read as data only.
    class Routes
      def initialize(files, erb: false)
        @files = Array(files)
        @erb = erb
      end

      # Prints the calls on out and the problems on err. Returns the exit code:
      # 2 if a file could not be read, else 1 if a file is not a valid
      # configuration, else 0.
      def report(out, err)
        rows = []
        codes = @files.map { |file| read(file, rows, err) }
        widths = [0, 1].map { |column| rows.map { |row| row[column].length }.max }
        rows.each { |call, verb, url| out.puts "#{call.ljust(widths[0])}  #{verb.ljust(widths[1])}  #{url}" }
        codes.max || 0
      end

      private

      # Adds the calls of file to rows. Returns the exit code for this file.
      def read(file, rows, err)
        unless File.file?(file) && File.readable?(file)
          err.puts "#{file}: #{File.file?(file) ? 'cannot be read' : (File.exist?(file) ? 'is not a file' : 'no such file')}"
          return 2
        end

        apis = if file.end_with?(Internals::Recipe::SUFFIX)
                 Internals::Recipe.read(file, compile: false).apis
               else
                 Configuration.new.read_recipe_file(file, erb: @erb)
               end
        Internals::Compiler.compile_all(apis).each_value do |api|
          api.routes.each { |route| rows << [route.call, Internals::OptionValue.shown_verb(route.verb), route.url] }
        end
        0
      rescue RecipeFileError => e
        e.errors.each { |problem| err.puts problem }
        1
      rescue ConfigurationError => e
        e.errors.each { |problem| err.puts "#{file}: #{problem}" }
        1
      rescue StandardError, ScriptError => e
        err.puts "#{file}: could not be evaluated (#{e.class})"
        1
      end
    end
  end
end
