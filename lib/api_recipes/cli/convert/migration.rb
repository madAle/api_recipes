# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require 'pathname'

module ApiRecipes
  module CLI
    class Convert
      # Moves one api of a project to a portable recipe, so that the project
      # works afterwards: the recipe is installed, the code of the ERB tags
      # goes to config.values in the file that calls ApiRecipes.configure, and
      # the old description is removed. Everything is worked out before
      # anything is written, and when a step cannot be done safely nothing is
      # changed. A file that exists is changed only when git has it committed,
      # so that every change can be seen and undone. Nothing is run.
      class Migration
        CONFIGURE = /^([ \t]*)ApiRecipes\.configure do \|([a-z_]\w*)\|[ \t]*$/
        SIMPLE_CODE = /\AENV(\[\s*(['"])\w+\2\s*\]|\.fetch\(\s*(['"])\w+\3\s*\))\z/

        # A file that exists is changed only when git knows it; lines are
        # taken out of one, and one is deleted, only when git has it committed
        # as it is now.
        def initialize(result, source, out:, err:, root: '.')
          @result = result
          @source = source
          @out = out
          @err = err
          @root = root
          @blocking = []
          @left = []
          @done = []
        end

        # Returns the exit code: 0 when the project was changed, 1 when it was
        # not, 2 when something could not be written.
        def call
          @project = Upgrade::Project.new(@root)
          @directory = Recipes::DEFAULT_DIRECTORY
          @target = File.join(@directory, "#{@result.name}#{Internals::Recipe::SUFFIX}")
          @blocking << "#{@target} already exists" if File.exist?(@target) || File.symlink?(@target)
          initializer = plan_initializer
          old = plan_old_description
          declarations = plan_verify_with
          return refused unless @blocking.empty?

          return 2 unless install

          write(initializer)
          declarations.each { |change| write(change) }
          remove(old)
          report
          0
        end

        private

        def shown(text) = Recipes::Summary.shown(text, 100)

        def text_of(file)
          bytes = File.binread(File.join(@root, file))
          text = bytes.force_encoding(Encoding::UTF_8)
          text.valid_encoding? && !bytes.include?("\0") ? text : nil
        rescue SystemCallError
          nil
        end

        # Whether git knows the file: then what this command adds to it shows
        # in `git diff`.
        def tracked?(file)
          _, known = Open3.capture2e('git', '-C', @root, 'ls-files', '--error-unmatch', '--', file)
          known.success?
        rescue SystemCallError
          false
        end

        # Whether git has the file committed as it is now: only then lines can
        # be taken out of it, or the file deleted, and brought back.
        def committed?(file)
          return false unless tracked?(file)

          changes, status = Open3.capture2e('git', '-C', @root, 'status', '--porcelain', '--', file)
          status.success? && changes.empty?
        rescue SystemCallError
          false
        end

        # Lines are only added to file: git must know it.
        def addable(file)
          return true if tracked?(file)

          @blocking << "#{shown(file)} is not in git: a change to it could not be seen or undone"
          false
        end

        # Lines are taken out of file, or the file is deleted: git must have
        # it as it is now.
        def removable(file)
          return true if committed?(file)

          @blocking << "#{shown(file)} is not committed in git as it is now: what is removed from it could not be brought back"
          false
        end

        # ---- the file that calls ApiRecipes.configure ----

        def plan_initializer
          files = @project.ruby_files.select { |file| @project.text(file).to_s.match?(/\bApiRecipes\.configure\b/) }
          if files.size != 1
            @blocking << (files.empty? ? 'no Ruby file of the project calls ApiRecipes.configure' : "ApiRecipes.configure is called in #{files.size} files (#{files.map { |file| shown(file) }.join(', ')})")
            return nil
          end

          file = files.first
          text = @project.text(file)
          edited = edited_initializer(file, text)
          return nil unless edited && addable(file)

          unless ruby?(edited)
            @blocking << "#{shown(file)} would not be valid Ruby after the change"
            return nil
          end
          [file, edited, 'recipes_paths and config.values']
        end

        def edited_initializer(file, text)
          unless text.scan(CONFIGURE).size == 1
            @blocking << "#{shown(file)}: ApiRecipes.configure is not written once as `ApiRecipes.configure do |config|`"
            return nil
          end
          lines = text.lines
          start = lines.index { |line| CONFIGURE.match?(line) }
          indent, config = CONFIGURE.match(lines[start]).captures
          finish = (start + 1...lines.size).find { |index| lines[index].match?(/\A#{Regexp.escape(indent)}end[ \t]*\r?\n?\z/) }
          if finish.nil?
            @blocking << "#{shown(file)}: the end of the block of ApiRecipes.configure was not found"
            return nil
          end

          body = lines[start + 1...finish]
          inner = "#{indent}  "
          body = with_values(body, file, config, inner)
          return nil if body.nil?

          unless body.any? { |line| line.match?(/\b#{config}\.recipes_paths\b/) }
            body << "#{inner}#{config}.recipes_paths = Dir[File.expand_path('#{recipes_glob(file)}', __dir__)]\n"
          end
          body[-1] = "#{body[-1]}\n" unless body.empty? || body[-1].end_with?("\n")
          (lines[0..start] + body + lines[finish..]).join
        end

        # The folder of the recipes, from the folder of the file.
        def recipes_glob(file)
          relative = Pathname.new(@directory).relative_path_from(Pathname.new(File.dirname(file))).to_s
          "#{relative}/*#{Internals::Recipe::SUFFIX}"
        end

        # The lines that give the variables of this api, one variable a line.
        # compact: a variable whose code gives nil is not given, so the
        # default of the recipe applies, or the request says which is missing.
        def entry(indent)
          pairs = @result.expressions.map do |name, code|
            "#{indent}  #{name}: #{code.match?(SIMPLE_CODE) || code.match?(/\A("[^"#\\]*"|'[^'\\]*'|\d+)\z/) ? code : "(#{code})"}"
          end
          ["#{indent}#{@result.name}: { variables: {\n", "#{pairs.join(",\n")}\n", "#{indent}}.compact }\n"]
        end

        # The lines of the block with the values of this api: in a new
        # config.values, or added to the one this command wrote before.
        def with_values(body, file, config, inner)
          return body if @result.expressions.empty?

          assigned = body.index { |line| line.match?(/\A\s*#{config}\.values\b/) }
          return body + ["#{inner}#{config}.values = {\n", *entry("#{inner}  "), "#{inner}}\n"] if assigned.nil?

          opening = /\A(\s*)#{config}\.values = \{[ \t]*\r?\n\z/.match(body[assigned])
          closing = opening && (assigned + 1...body.size).find { |index| body[index].match?(/\A#{Regexp.escape(opening[1])}\}[ \t]*\r?\n?\z/) }
          taken = closing && body[assigned + 1...closing].any? { |line| line.match?(/\A\s*#{Regexp.escape(@result.name)}:/) }
          if closing.nil? || taken
            @blocking << "#{shown(file)}: config.values is already assigned in a way this command does not edit" \
                         "#{' and already has this api' if taken}"
            return nil
          end

          last = (assigned + 1...closing).to_a.reverse.find { |index| !body[index].strip.empty? }
          body = body.dup
          body[last] = body[last].sub(/[ \t]*(\r?\n)\z/, ',\1') if last && !body[last].rstrip.end_with?(',')
          body.insert(closing, *entry("#{opening[1]}  "))
        end

        # Reads the text as Ruby without running it.
        def ruby?(text)
          require 'prism'
          Prism.parse(text).success?
        rescue LoadError
          RubyVM::InstructionSequence.compile(text) && true
        rescue SyntaxError
          false
        end

        # ---- the old description ----

        def plan_old_description
          return nil unless removable(@source)

          text = text_of(@source)
          others = Convert.shape(text)
          return [@source, nil] if others.keys == [@result.name]

          lines = text.lines
          start = lines.index { |line| line.match?(/\A(['"]?)#{Regexp.escape(@result.name)}\1:/) }
          finish = start && ((start + 1...lines.size).find { |index| lines[index].match?(/\A[^\s#]/) } || lines.size)
          rest = start && (lines[0...start] + lines[finish..]).join
          others.delete(@result.name)
          if rest.nil? || Convert.shape(rest) != others
            @blocking << "#{shown(@source)} describes other apis too, and the lines of #{@result.name} could not be taken out of it safely"
            return nil
          end
          [@source, rest]
        rescue Refused, Psych::Exception
          @blocking << "#{shown(@source)} describes other apis too, and the lines of #{@result.name} could not be taken out of it safely"
          nil
        end

        # ---- verify_with ----

        # A recipe cannot carry verify_with: the one of the api goes where a
        # class declares the api, when that line can be edited safely.
        def plan_verify_with
          changes = []
          @result.verify_with.each do |place, method|
            lines = place == 'verify_with' ? declaration_lines : []
            usable = Internals::Compiler::METHOD_NAME.match?(method) && !lines.empty? &&
                     lines.all? { |file, _, line| line.match?(/\A\s*api :#{Regexp.escape(@result.name)}(?:\b[^#\\]*[^#\\,({\s])?\s*\z/) && tracked?(file) }
            unless usable
              @left << "#{shown(place)}: was left out of the recipe and could not be written in the code: give it where a class " \
                       "declares the api, as `api :#{@result.name}, verify_with: ...`, or the answers are no longer verified"
              next
            end
            lines.group_by(&:first).each do |file, found|
              text = @project.text(file).lines
              found.each { |_, number, _| text[number] = text[number].sub(/\s*\z/) { |ending| ", verify_with: :#{method}#{ending}" } }
              changes << [file, text.join, 'verify_with on the declaration of the api']
            end
          end
          changes
        end

        # [file, index of the line, line] for each `api :name` of this api.
        def declaration_lines
          @project.ruby_files.flat_map do |file|
            @project.text(file).to_s.lines.each_with_index.select { |line, _| line.match?(/\A\s*api[ \t(]+:#{Regexp.escape(@result.name)}\b/) }
                    .reject { |line, _| line.include?('verify_with') }.map { |line, index| [file, index, line] }
          end
        end

        # ---- writing ----

        def install
          Dir.mktmpdir do |dir|
            file = File.join(dir, "#{@result.name}#{Internals::Recipe::SUFFIX}")
            File.write(file, @result.text)
            quiet = StringIO.new
            code = Recipes.new(out: quiet, err: quiet, input: StringIO.new).install(file, directory: File.join(@root, @directory), yes: true)
            next true.tap { @done << ['created', "#{@target}, with its line in #{File.join(@directory, Internals::RecipeLock::FILE_NAME)}"] } if code.zero?

            @err.puts "#{@target} could not be installed: nothing was changed"
            false
          end
        end

        def write(change)
          return if change.nil?

          file, text, what = change
          File.write(File.join(@root, file), text)
          @done << ['edited', "#{shown(file)}: #{what}"]
        end

        def remove(old)
          return if old.nil?

          file, rest = old
          if rest.nil?
            File.delete(File.join(@root, file))
            @done << ['deleted', shown(file)]
          else
            File.write(File.join(@root, file), rest)
            @done << ['edited', "#{shown(file)}: the lines of #{@result.name} are gone"]
          end
        end

        # ---- what is said ----

        def refused
          @err.puts "#{shown(@source)} can become a portable recipe, but the project was not changed:"
          @blocking.each { |reason| @err.puts "  - #{reason}" }
          @err.puts "Nothing was written. `api_recipes convert #{shown(@source)} --to DIR` writes the recipe alone, " \
                    'and says what the application gives.'
          1
        end

        def report
          calls = @result.calls
          @out.puts "#{@result.name} #{@result.version} now comes from a portable recipe: #{calls} call#{'s' unless calls == 1}"
          @out.puts '', 'Changed in the project'
          @done.each { |verb, what| @out.puts "  #{verb.ljust(8)} #{what}" }
          unless @result.changes.empty?
            @out.puts '', 'What changed in the description'
            @result.changes.each { |change| @out.puts "  #{change}" }
          end
          unless @left.empty?
            @out.puts '', 'Left to you'
            @left.each { |one| @out.puts "  - #{one}" }
          end
          @out.puts '', 'Every change is in `git status` and `git diff`, and `git checkout` undoes it. Check the recipes with ' \
                        '`api_recipes check`, then start the application.'
        end
      end
    end
  end
end
