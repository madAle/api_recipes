# frozen_string_literal: true

require 'securerandom'

module ApiRecipes
  module CLI
    # The routes command: the calls that the recipes in some files offer, one
    # per line, with the verb and the address. A file called NAME.recipe.yml is
    # a portable recipe, read as data only.
    class Routes
      STRUCTURE = 'contains ERB that decides the structure of the file (<% ... %>): run again with --erb to evaluate it ' \
                  '(this executes the code in the file)'

      # project: the files were found in the project, not given: their names
      # are shown without what a terminal would obey.
      def initialize(files, erb: false, project: false)
        @files = Array(files)
        @erb = erb
        @project = project
        # What stands for the value of an ERB tag: random, so that no file can write it.
        @mark = "API_RECIPES_ERB_#{SecureRandom.hex(6)}"
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

      def shown(file) = @project ? Recipes::Summary.shown(file, 300) : file

      # Adds the calls of file to rows. Returns the exit code for this file.
      def read(file, rows, err)
        unless File.file?(file) && File.readable?(file)
          err.puts "#{shown(file)}: #{File.file?(file) ? 'cannot be read' : (File.exist?(file) ? 'is not a file' : 'no such file')}"
          return 2
        end

        tags = false
        apis = if file.end_with?(Internals::Recipe::SUFFIX)
                 Internals::Recipe.read(file, compile: false).apis
               else
                 Description.read(file, erb: @erb) do |text|
                   tags = true
                   Tags.replaced(text, @mark) || raise(RecipeFileError.new(file, STRUCTURE))
                 end
               end
        apis = with_tags_shown(file, apis) if tags
        Internals::Compiler.compile_all(apis).each_value do |api|
          api.routes.each { |route| rows << [route.call, Internals::OptionValue.shown_verb(route.verb), route.url] }
        end
        err.puts "#{shown(file)}: what an ERB tag gives is shown as {erb}; --erb evaluates the file, which runs the code in it" if tags
        0
      rescue RecipeFileError => e
        e.errors.each { |problem| err.puts(@project ? "#{shown(file)}: #{problem.delete_prefix("#{file}: ")}" : problem) }
        1
      rescue ConfigurationError => e
        e.errors.each { |problem| err.puts "#{shown(file)}: #{problem}" }
        1
      rescue StandardError, ScriptError, SystemStackError => e
        err.puts "#{shown(file)}: could not be evaluated (#{e.class})"
        1
      end

      # The apis with what each ERB tag gives written as a variable, which
      # every api declares for it: the calls are listed, the tags are not run.
      def with_tags_shown(file, apis)
        apis.to_h do |name, options|
          raise RecipeFileError.new(file, 'an ERB tag gives a name: run again with --erb to evaluate it (this executes the code in the file)') if names_a_key?(name => options)
          next [name, options] unless options.is_a?(Hash) && options.to_s.include?(@mark)

          declared = options[:variables].is_a?(Hash) ? options[:variables] : {}
          variable = declared.key?(:erb) ? 'erb_tag' : 'erb'
          [name, shown_as(options, "{#{variable}}").merge(variables: declared.merge(variable.to_sym => nil))]
        end
      end

      def names_a_key?(value)
        case value
        when Hash then value.any? { |key, inner| key.to_s.include?(@mark) || names_a_key?(inner) }
        when Array then value.any? { |inner| names_a_key?(inner) }
        else false
        end
      end

      def shown_as(value, variable)
        case value
        when Hash then value.transform_values { |inner| shown_as(inner, variable) }
        when Array then value.map { |inner| shown_as(inner, variable) }
        when String then value.include?(@mark) ? value.gsub(@mark, variable) : value
        else value
        end
      end
    end
  end
end
