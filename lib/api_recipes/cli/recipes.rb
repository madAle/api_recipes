# frozen_string_literal: true

require 'fileutils'
require 'api_recipes/cli/recipes/summary'
require 'api_recipes/cli/recipes/git'
require 'api_recipes/cli/recipes/lock_file'

module ApiRecipes
  module CLI
    # The commands for portable recipes: check, install and update.
    class Recipes
      DEFAULT_DIRECTORY = 'config/api_recipes'
      DEFAULT_SOURCE = 'https://github.com/madAle/api_recipes-cookbook'
      Recipe = Internals::Recipe
      RecipeLock = Internals::RecipeLock

      # A recipe about to be installed: where it comes from, for the lock
      # (source and commit, nil for a file) and for the reader (origin).
      Incoming = Data.define(:recipe, :source, :commit, :origin)

      # The command ends here, with this exit code and this message.
      class Stop < StandardError
        attr_reader :code

        def initialize(code, message)
          @code = code
          super(message)
        end
      end

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

      # Installs the recipe called target from the repository at from, at
      # version or at the head; or the file at target, when target is not the
      # name of a recipe. Shows what the recipe does and asks before writing
      # in directory. Returns the exit code: 1 if the recipe is not acceptable,
      # is not found or the answer is no, 2 if the arguments are wrong or
      # something could not be read or written, else 0.
      def install(target, version: nil, from: nil, directory: DEFAULT_DIRECTORY, yes: false)
        guarded do
          incoming = Recipe::NAME.match?(target) ? fetched(target, version, from || DEFAULT_SOURCE, '--from') : local(target, version, from)
          place(incoming, directory, yes, 'Install')
        end
      end

      # Replaces an installed recipe with the one its repository has now, or
      # has at version, after showing what changes. Same exit codes as install.
      def update(name, version: nil, directory: DEFAULT_DIRECTORY, yes: false)
        guarded do
          raise Stop.new(2, "#{Summary.shown(name, 80)} is not the name of a recipe") unless Recipe::NAME.match?(name)

          readable!(File.join(directory, RecipeLock::FILE_NAME))
          entry = RecipeLock.read(directory)[name]
          raise Stop.new(1, "#{name} is not installed in #{directory}") if entry.nil?
          if entry.source.nil?
            raise Stop.new(1, "#{name} was installed from a file: install the new file with `api_recipes install FILE`")
          end

          place(fetched(name, version, entry.source, "#{File.join(directory, RecipeLock::FILE_NAME)}: the source of #{name}"),
                directory, yes, 'Update')
        end
      end

      private

      def guarded
        yield
      rescue Stop => e
        @err.puts e.message
        e.code
      rescue ConfigurationError => e
        e.errors.each { |problem| @err.puts problem }
        1
      rescue Git::NotFound => e
        @err.puts e.message
        1
      rescue Git::Failure => e
        @err.puts e.message
        2
      rescue SystemCallError => e
        @err.puts "could not write (#{e.class.name.split('::').last}): check the folder and its recipes.lock"
        2
      end

      def fetched(name, version, address, what)
        problem = Git.address_problem(address)
        raise Stop.new(2, "#{what} #{problem}") if problem
        unless version.nil? || (version.length <= Recipe::MAX_VERSION && Recipe::VERSION.match?(version))
          raise Stop.new(2, '--version must be made of digits, letters and dots')
        end

        # Said before git connects: the address may come from the lock, and
        # git or ssh may ask something on the terminal for it.
        @out.puts "reading #{name} from #{address}"
        @out.flush if @out.respond_to?(:flush)
        found = Git.new(address, ask: terminal?).fetch(name, version)
        recipe = Recipe.parse(found.text, "#{name} in #{address}", file_name: "#{name}#{Recipe::SUFFIX}")
        if version && recipe.version != version
          raise Stop.new(1, "the tag #{name}-#{version} of #{address} holds version #{recipe.version}: nothing was written")
        end

        Incoming.new(recipe: recipe, source: address, commit: found.commit, origin: "#{address}, commit #{found.commit[0, 12]}")
      end

      # Whether someone is there to answer: the input of the command is a terminal.
      def terminal? = @input.respond_to?(:tty?) && @input.tty? ? true : false

      def local(path, version, from)
        raise Stop.new(2, '--from and --version go with the name of a recipe, not with a file') if version || from
        unless File.file?(path) && File.readable?(path)
          shown = Summary.shown(path)
          raise Stop.new(2, "#{shown}: #{File.file?(path) ? 'cannot be read' : (File.exist?(path) ? 'is not a file' : 'no such file')}")
        end

        Incoming.new(recipe: Recipe.read(path), source: nil, commit: nil, origin: "the file #{Summary.shown(path)}")
      end

      # Shows the recipe, asks, then writes its file and the lock of directory.
      def place(incoming, directory, yes, action)
        recipe = incoming.recipe
        destination = File.join(directory, "#{recipe.name}#{Recipe::SUFFIX}")
        lock_path = File.join(directory, RecipeLock::FILE_NAME)
        [destination, lock_path].each do |path|
          raise Stop.new(2, "#{path} is a link: api_recipes does not write through links") if File.symlink?(path)
        end
        raise Stop.new(2, "#{directory} is not a folder") if File.exist?(directory) && !File.directory?(directory)

        [destination, lock_path].each { |path| readable!(path) }
        lock = RecipeLock.read(directory)
        entry = RecipeLock::Entry.new(version: recipe.version, source: incoming.source, commit: incoming.commit,
                                      sha256: recipe.sha256)
        current = installed_text(destination)
        summary = Summary.new(recipe, origin: incoming.origin)
        if current == recipe.text && lock[recipe.name] == entry
          @out.puts "#{summary.title} is already installed in #{directory}: nothing to do"
          return 0
        end

        show(summary, destination, current, lock[recipe.name])
        confirm("#{action} #{summary.title} in #{directory}?") unless yes
        FileUtils.mkdir_p(directory)
        write(destination, recipe.text) unless current == recipe.text
        write(lock_path, LockFile.text(lock.entries.merge(recipe.name => entry)))
        @out.puts "#{recipe.name} #{recipe.version} is installed in #{destination}"
        0
      end

      def installed_text(destination)
        return nil unless File.exist?(destination)
        raise Stop.new(2, "#{destination} is not a file") unless File.file?(destination)

        Recipe.read_text(destination).first
      end

      def show(summary, destination, current, entry)
        summary.lines.each { |line| @out.puts line }
        summary.warnings.each { |warning| @out.puts "  warning: #{warning}" }
        return if current.nil? || current == summary.text

        if entry && entry.sha256 != Recipe.digest(current)
          @out.puts "  #{destination} was changed after it was installed: those changes will be lost"
        end
        summary.changes_from(installed_summary(current, destination)).each { |line| @out.puts line }
      end

      # The summary of the recipe that is installed now; nil when it is not a
      # valid recipe.
      def installed_summary(text, destination)
        Summary.new(Recipe.parse(text, destination))
      rescue ConfigurationError
        nil
      end

      def confirm(question)
        @out.print "#{question} [y/N] "
        @out.flush if @out.respond_to?(:flush)
        answer = @input&.gets.to_s.strip.downcase
        raise Stop.new(1, 'nothing was written') unless %w[y yes].include?(answer)
      end

      # The new content takes the place of the file in one step. The bytes are
      # written as they are, on every system: the checksum is of the bytes.
      def write(path, text)
        temporary = "#{path}.#{Process.pid}.tmp"
        file = File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644)
        begin
          file.write(text)
          file.close
          File.rename(temporary, path)
        ensure
          file.close unless file.closed?
          File.delete(temporary) if File.exist?(temporary)
        end
      end

      # A file that is there and cannot be read stops the command with 2.
      def readable!(path)
        raise Stop.new(2, "#{path}: cannot be read") if File.exist?(path) && !File.readable?(path)
      end

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

        readable!(File.join(directory, RecipeLock::FILE_NAME))
        lock = RecipeLock.read(directory)
        names = Dir.children(directory).select { |name| name.end_with?(Recipe::SUFFIX) }.sort
        codes = names.map { |name| check_installed(File.join(directory, name), name.delete_suffix(Recipe::SUFFIX), lock) }
        (lock.entries.keys - names.map { |name| name.delete_suffix(Recipe::SUFFIX) }).sort.each do |name|
          @err.puts "#{lock.path}: #{name} is in the lock, but #{File.join(directory, "#{name}#{Recipe::SUFFIX}")} is missing"
          codes << 1
        end
        @out.puts "no recipes in #{directory}" if codes.empty?
        codes.max || 0
      rescue Stop => e
        @err.puts e.message
        e.code
      rescue ConfigurationError => e
        e.errors.each { |problem| @err.puts problem }
        1
      rescue SystemCallError => e
        @err.puts "#{directory}: cannot be read (#{e.class.name.split('::').last})"
        2
      end

      def check_installed(file, name, lock)
        unless File.readable?(file)
          @err.puts "#{file}: cannot be read"
          return 2
        end

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
