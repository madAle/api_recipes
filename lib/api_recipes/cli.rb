# frozen_string_literal: true

require 'optparse'
require 'fileutils'
require 'api_recipes'
require 'api_recipes/version'
require 'api_recipes/cli/upgrade'
require 'api_recipes/cli/import'
require 'api_recipes/cli/routes'
require 'api_recipes/cli/recipes'
require 'api_recipes/cli/convert'

module ApiRecipes
  # The api_recipes command. It is not loaded by `require 'api_recipes'`.
  module CLI
    USAGE = <<~TEXT
      Usage: api_recipes COMMAND [options]

      Commands:
        upgrade [--config FILE]... [--erb] [PATH]...
            Without arguments, in the root of a project: finds its Ruby files and the files
            that describe an api, and looks for what changed in api_recipes 3.0. It says what
            it checked. With arguments: the Ruby files under each PATH, and each configuration
            FILE checked with the 3.0 rules. It never changes a file. A file that contains ERB
            is checked without running its code, leaving out what its tags give; --erb
            evaluates it instead: this runs the code in it.
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
            A file called NAME.recipe.yml is read as a portable recipe: as data only.
            Exits with 1 if a file is not a valid configuration, 2 if it could not read one.
        convert [--name NAME] [--version VERSION] [--to DIR] FILE
            Writes NAME.recipe.yml, a portable recipe, from the configuration FILE of a
            project, in DIR (the current folder). The file is created, never replaced.
            Nothing in FILE is run: an ERB tag becomes a variable where a recipe can have
            one, and is left out elsewhere. A header or a parameter named like a credential
            is never copied: it becomes a variable. verify_with is left out. --name chooses
            the api when FILE describes several; --version is the version of the recipe
            (1.0.0). It says what changed and what the application gives from now on.
            Exits with 1 if FILE cannot become a recipe, 2 if the arguments are wrong or
            something could not be read or written.
        install [--version VERSION] [--from URL] [--to DIR] [--yes] NAME|FILE
            Installs the portable recipe called NAME from the cookbook
            (https://github.com/madAle/api_recipes-cookbook) or from the Git repository at URL,
            an https:// or ssh address (ssh://HOST/PATH, USER@HOST:PATH) that holds
            recipes/NAME.recipe.yml. On a terminal git may ask for the user name and the password
            of an https repository. Without --version
            it takes the recipe at the head of the repository, with it the one at the tag
            NAME-VERSION. Given a FILE, it installs that file. It shows where the requests and
            the credential go, the headers and which calls are not GET, asks, then writes NAME.recipe.yml and
            recipes.lock in DIR (config/api_recipes). --yes installs without asking.
            Exits with 1 if the recipe is not valid, is not found or the answer is no, 2 if the
            arguments are wrong, git failed or something could not be read or written.
        update [--version VERSION] [--dir DIR] [--yes] NAME
            Replaces the recipe NAME installed in DIR with the one its repository has now, or
            has at VERSION, after showing what changes in the address, the credential, the
            headers and the verbs. Same exit codes as install.
        check [--dir DIR] [FILE]...
            Checks that each FILE is a valid portable recipe. Without a FILE, checks that the
            recipes installed in DIR (config/api_recipes) are the ones written in its
            recipes.lock, as ApiRecipes.configure does when the application starts.
            Exits with 1 if something is not valid or does not match, 2 if it could not read
            something.

      Options:
        --version   print the version
        --help      print this help
    TEXT

    class << self
      # Returns the exit code.
      def run(argv, out: $stdout, err: $stderr, input: $stdin)
        command, *args = argv
        unless argv.all?(&:valid_encoding?)
          err.puts 'the arguments must be valid text in the encoding of the terminal'
          return 2
        end

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
        when 'convert'
          convert(args, out, err)
        when 'check'
          check(args, out, err)
        when 'install', 'update'
          place(command, args, out, err, input)
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
        problem = import_problem(paths, output, options[:name])
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
      rescue StandardError => e
        # The description is someone else's: what the importer did not foresee
        # is answered with one line, never with the text of an exception.
        err.puts "import failed (#{e.class}): this is a defect of api_recipes, not of the description"
        1
      end

      def import_problem(paths, output, name)
        return 'import needs one OpenAPI file' unless paths.size == 1
        unless name.nil? || Internals::Compiler::METHOD_NAME.match?(name)
          return '--name: must be the name of a method: letters, digits and _, not starting with a digit'
        end
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
      rescue Errno::EPIPE
        # The reader of STDOUT went away, as in `api_recipes import ... | head`.
        true
      rescue SystemCallError => e
        err.puts "#{output || 'the recipe'}: cannot be written (#{e.class.name.split('::').last})"
        false
      end

      def convert(args, out, err)
        options = {}
        directory = '.'
        parser = OptionParser.new
        parser.on('--name NAME') { |name| options[:name] = name }
        parser.on('--version VERSION') { |version| options[:version] = version }
        parser.on('--to DIR') { |dir| directory = dir }
        files = parser.parse(args)
        unless files.size == 1
          err.puts 'convert needs one configuration file'
          return 2
        end

        result = Convert.new(files.first, **options).call
        file_name = "#{result.name}#{Internals::Recipe::SUFFIX}"
        path = directory == '.' ? file_name : File.join(directory, file_name)
        return 2 unless place_recipe(result.text, directory, path, err)

        Convert.report(result, files.first, path).each { |line| out.puts line }
        0
      rescue Convert::Refused => e
        e.reasons.each { |reason| err.puts reason }
        1
      rescue Convert::Unusable, OptionParser::ParseError => e
        err.puts e.message
        2
      end

      # The recipe is created in its folder, never replaced.
      def place_recipe(text, directory, path, err)
        FileUtils.mkdir_p(directory)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(text) }
        true
      rescue Errno::EEXIST
        err.puts "#{path} already exists: remove it, or choose another folder with --to"
        false
      rescue SystemCallError => e
        err.puts "#{path}: cannot be written (#{e.class.name.split('::').last})"
        false
      end

      def check(args, out, err)
        directory = Recipes::DEFAULT_DIRECTORY
        parser = OptionParser.new
        parser.on('--dir DIR') { |dir| directory = dir }
        files = parser.parse(args)
        Recipes.new(out: out, err: err).check(files, directory: directory)
      rescue OptionParser::ParseError => e
        err.puts e.message
        2
      end

      def place(command, args, out, err, input)
        options = { directory: Recipes::DEFAULT_DIRECTORY, yes: false }
        parser = OptionParser.new
        parser.on('--version VERSION') { |version| options[:version] = version }
        parser.on('--dir DIR') { |dir| options[:directory] = dir }
        parser.on('--yes') { options[:yes] = true }
        if command == 'install'
          parser.on('--from URL') { |url| options[:from] = url }
          parser.on('--to DIR') { |dir| options[:directory] = dir }
        end
        targets = parser.parse(args)
        unless targets.size == 1
          err.puts command == 'install' ? 'install needs the name of one recipe, or one file' : 'update needs the name of one recipe'
          return 2
        end

        Recipes.new(out: out, err: err, input: input).public_send(command, targets.first, **options)
      rescue OptionParser::ParseError => e
        err.puts e.message
        2
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
        return Upgrade.new(paths, config: configs, erb: erb).report(out, err) unless paths.empty? && configs.empty?

        unless File.file?('Gemfile')
          err.puts 'upgrade without arguments checks the project in the current directory, and there is no Gemfile ' \
                   'here: run it in the root of the project, or name the directories and the files to check'
          return 2
        end

        Upgrade.for_project(Upgrade::Project.new, erb: erb).report(out, err)
      rescue OptionParser::ParseError => e
        err.puts e.message
        2
      end
    end
  end
end
