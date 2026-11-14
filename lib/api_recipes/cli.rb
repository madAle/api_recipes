# frozen_string_literal: true

require 'optparse'
require 'api_recipes'
require 'api_recipes/version'
require 'api_recipes/cli/upgrade'
require 'api_recipes/cli/import'
require 'api_recipes/cli/routes'

module ApiRecipes
  # The api_recipes command. It is not loaded by `require 'api_recipes'`.
  module CLI
    USAGE = <<~TEXT
      Usage: api_recipes COMMAND [options]

      Commands:
        upgrade [--config FILE]... [--erb] [PATH]...
            Looks in the Ruby files under each PATH for what changed in api_recipes 3.0
            and checks each configuration FILE with the 3.0 rules. It never changes a file.
            A file that contains ERB is evaluated only with --erb: this runs the code in it.
            Exits with 1 if it finds something, 2 if it could not read something, 0 otherwise.
        import [--name NAME] [--only GLOB]... [--except GLOB]... [--server N] [--output FILE] FILE
            Writes a recipe from the OpenAPI 3.0 or 3.1 description in FILE (YAML or JSON), on
            STDOUT or in the file given with --output, which must not exist. Warnings and a
            summary go to STDERR. --only and --except choose the paths: * also crosses slashes.
            --server chooses the entry of servers, counted from 0. Nothing in FILE is run, no
            other file is read and the network is not used.
            Exits with 1 if the description cannot be imported, 2 if the arguments are wrong.
        routes [--erb] FILE...
            Lists the calls that the recipes in each FILE offer, with the verb and the address.
            A file that contains ERB is evaluated only with --erb: this runs the code in it.
            Exits with 1 if a file is not a valid configuration, 2 if it could not read one.

      Options:
        --version   print the version
        --help      print this help
    TEXT

    class << self
      # Returns the exit code.
      def run(argv, out: $stdout, err: $stderr)
        command, *args = argv
        case command
        when '--version', '-v'
          out.puts ApiRecipes::VERSION
          0
        when '--help', '-h'
          out.puts USAGE
          0
        when 'upgrade'
          upgrade(args, out, err)
        when 'import'
          import(args, out, err)
        when 'routes'
          routes(args, out, err)
        when nil
          err.puts USAGE
          2
        else
          err.puts "unknown command: #{command}"
          err.puts USAGE
          2
        end
      end

      private

      def import(args, out, err)
        options = { only: [], except: [] }
        output = nil
        parser = OptionParser.new
        parser.on('--name NAME') { |name| options[:name] = name }
        parser.on('--only GLOB') { |glob| options[:only] << glob }
        parser.on('--except GLOB') { |glob| options[:except] << glob }
        parser.on('--server N', Integer) { |number| options[:server] = number }
        parser.on('--output FILE') { |file| output = file }
        paths = parser.parse(args)
        problem = import_problem(paths, output)
        if problem
          err.puts problem
          return 2
        end

        result = Import.new(paths.first, **options).call
        return 2 unless write_recipe(result.text, output, out, err)

        result.warnings.each { |warning| err.puts "warning: #{warning}" }
        err.puts result.summary
        0
      rescue Import::Error => e
        err.puts e.message
        1
      rescue OptionParser::ParseError => e
        err.puts e.message
        2
      end

      def import_problem(paths, output)
        return 'import needs one OpenAPI file' unless paths.size == 1
        return "#{paths.first}: no such file" unless File.exist?(paths.first)
        return "#{paths.first}: is not a file that can be read" unless File.file?(paths.first) && File.readable?(paths.first)
        return "#{output} already exists: remove it or choose another name" if output && File.exist?(output)

        nil
      end

      # The file of --output is created, never replaced.
      def write_recipe(text, output, out, err)
        if output
          File.open(output, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(text) }
        else
          out.write(text)
        end
        true
      rescue SystemCallError => e
        err.puts "#{output}: cannot be written (#{e.class.name.split('::').last})"
        false
      end

      def routes(args, out, err)
        erb = false
        parser = OptionParser.new
        parser.on('--erb') { erb = true }
        files = parser.parse(args)
        if files.empty?
          err.puts 'routes needs at least one configuration file'
          return 2
        end

        Routes.new(files, erb: erb).report(out, err)
      rescue OptionParser::ParseError => e
        err.puts e.message
        2
      end

      def upgrade(args, out, err)
        configs = []
        erb = false
        parser = OptionParser.new
        parser.on('--config FILE') { |file| configs << file }
        parser.on('--erb') { erb = true }
        paths = parser.parse(args)
        if paths.empty? && configs.empty?
          err.puts 'upgrade needs a directory or a file to scan, or --config FILE'
          return 2
        end

        Upgrade.new(paths, config: configs, erb: erb).report(out, err)
      rescue OptionParser::ParseError => e
        err.puts e.message
        2
      end
    end
  end
end
