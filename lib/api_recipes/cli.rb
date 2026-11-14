# frozen_string_literal: true

require 'optparse'
require 'api_recipes'
require 'api_recipes/version'
require 'api_recipes/cli/upgrade'

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
