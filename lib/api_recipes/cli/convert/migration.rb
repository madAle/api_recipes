# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require 'pathname'
require 'fileutils'

module ApiRecipes
  module CLI
    class Convert
      # Moves one api of a project to a portable recipe, so that the project
      # works afterwards: the recipe is installed, the code of the ERB tags
      # goes to config.values in the file that calls ApiRecipes.configure, and
      # the old description is removed.
      #
      # Ruby is read as a tree, never matched as lines and never run. Every
      # change is worked out in memory, on the text as the changes before it
      # left it, and each result must be valid Ruby. When a step cannot be
      # done safely nothing is written. A write that fails puts every file
      # back as it was. A file that exists is changed only when it is a plain
      # file of the project that git tracks; lines are taken out of one, and
      # one is deleted, only when git has it committed as it is now.
      class Migration
        SIMPLE_CODE = /\AENV(\[\s*(['"])\w+\2\s*\]|\.fetch\(\s*(['"])\w+\3\s*\))\z/
        PLAIN_CODE = /\A("(?:[^"#\\]|\\.)*"|'[^'\\]*'|\d+)\z/
        # git does not run a program that the repository names.
        GIT = ['git', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null'].freeze

        def initialize(result, source, out:, err:, root: '.')
          @result = result
          @source = source
          @out = out
          @err = err
          @root = root
          @blocking = []
          @left = []
          @done = []
          # The text each file will have: nil for a file that is deleted.
          @planned = {}
          @notes = {}
        end

        # Returns the exit code: 0 when the project was changed, 1 when it was
        # not, 2 when something could not be written.
        def call
          @project = Upgrade::Project.new(@root)
          inside = Pathname.new(File.expand_path(@source)).relative_path_from(Pathname.new(File.expand_path(@root))).to_s
          @source = inside unless inside.start_with?('..')
          @directory = Recipes::DEFAULT_DIRECTORY
          @target = File.join(@directory, "#{@result.name}#{Internals::Recipe::SUFFIX}")
          @lock = File.join(@directory, Internals::RecipeLock::FILE_NAME)
          place_problems
          plan_initializer
          plan_verify_with
          plan_old_description
          plan_valid
          return refused unless @blocking.empty?
          return 2 unless apply

          report
          0
        end

        private

        def shown(text) = Recipes::Summary.shown(text, 100)

        def full(file) = File.join(@root, file)

        # The text a file has now, with the changes planned so far.
        def text_of(file)
          return @planned[file] if @planned.key?(file)

          bytes = File.binread(full(file))
          text = bytes.force_encoding(Encoding::UTF_8)
          text.valid_encoding? && !bytes.include?("\0") ? text : nil
        rescue SystemCallError
          nil
        end

        def plan(file, text, note)
          @planned[file] = text
          (@notes[file] ||= []) << note
        end

        # ---- what git knows ----

        def git(*arguments)
          Open3.capture2e({ 'GIT_OPTIONAL_LOCKS' => '0' }, *GIT, '-C', @root, *arguments)
        rescue SystemCallError
          ['', nil]
        end

        # Whether file is a plain file of the project: not a symbolic link, not
        # below one, and not outside the project.
        def plain?(file)
          path = full(file)
          return false if File.symlink?(path) || !File.file?(path)

          File.realpath(path) == File.join(File.realpath(@root), Pathname.new(file).cleanpath.to_s)
        rescue SystemCallError
          false
        end

        # Whether git tracks the file as it does any other: `H` is what it
        # says of a file that is neither skipped nor assumed unchanged.
        def tracked?(file)
          out, status = git('ls-files', '-v', '--error-unmatch', '--', file)
          return false unless plain?(file) && status&.success? && out.start_with?('H ')

          # A file only announced to git (add -N) has nothing to go back to.
          _, known = git('cat-file', '-e', "HEAD:./#{Pathname.new(file).cleanpath}")
          known&.success? ? true : false
        end

        # Whether git has the file committed as it is now.
        def committed?(file)
          return false unless tracked?(file)

          changes, status = git('status', '--porcelain', '--', file)
          status&.success? && changes.empty?
        end

        def git_reason(file)
          _, status = git('--version')
          return 'git was not found: without it a change could not be seen or undone' unless status&.success?
          return "#{shown(file)} is a symbolic link, or is below one: this command changes only the files of the project" unless plain?(file)

          nil
        end

        # Lines are only added to file: git must know it.
        def addable(file)
          return true if tracked?(file) && File.writable?(full(file))

          @blocking << (git_reason(file) || "#{shown(file)} is not a file that git tracks and that can be written: " \
                                           'a change to it could not be seen or undone')
          false
        end

        # Lines are taken out of file, or the file is deleted: git must have
        # it as it is now.
        def removable(file)
          return true if committed?(file) && File.writable?(full(file)) && File.writable?(File.dirname(full(file)))

          @blocking << (git_reason(file) || "#{shown(file)} is not committed in git as it is now, or cannot be written: " \
                                           'what is removed from it could not be brought back')
          false
        end

        # ---- where the recipe goes ----

        def place_problems
          directory = full(@directory)
          @blocking << "#{@target} already exists" if File.exist?(full(@target)) || File.symlink?(full(@target))
          @blocking << "#{@directory} is a symbolic link: the recipe would be written outside the project" if File.symlink?(directory)
          _, ignored = git('check-ignore', '-q', '--', @target)
          @blocking << "#{@target} would be ignored by git: the recipe would not be committed with the rest" if ignored&.success?
          lock_problem
          also = (@project.config_files - [Pathname.new(@source).cleanpath.to_s]).select do |file|
            !file.end_with?(Internals::Recipe::SUFFIX) && Convert.shape(@project.text(file).to_s).key?(@result.name)
          rescue Refused, Psych::Exception
            false
          end
          @blocking << "#{@result.name} is described in #{also.map { |file| shown(file) }.join(', ')} too: a recipe never takes the place of an api" unless also.empty?
        end

        # A recipes.lock that is there is rewritten with one more line: it must
        # be a plain file that reads as a lock.
        def lock_problem
          return unless File.exist?(full(@lock)) || File.symlink?(full(@lock))
          return @blocking << "#{@lock} is not a plain file of the project" unless plain?(@lock) && File.writable?(full(@lock))

          Internals::RecipeLock.read(full(@directory))
        rescue ConfigurationError
          @blocking << "#{@lock} cannot be read as a lock: this command would rewrite it"
        end

        # ---- the file that calls ApiRecipes.configure ----

        def plan_initializer
          files = @project.ruby_files.select { |file| @project.text(file).to_s.include?('ApiRecipes') && Code::ConfigureBlock.in(@project.text(file)) }
          if files.size != 1
            @blocking << (files.empty? ? 'no Ruby file of the project calls ApiRecipes.configure once' : "ApiRecipes.configure is called in #{files.size} files (#{files.map { |file| shown(file) }.join(', ')})")
            return
          end

          @initializer = files.first
          text = text_of(@initializer)
          block = Code::ConfigureBlock.in(text)
          if block.problem
            @blocking << "#{shown(@initializer)}: the call to ApiRecipes.configure #{block.problem}"
            return
          end

          problems = @blocking.size
          added = values_edits(block, text) + recipes_edits(block)
          # What is added goes at one place, in this order.
          comma, added = added.partition { |from, _, _| from != block.end_offset }
          edits = comma + files_edits(block, text)
          edits << [block.end_offset, block.end_offset, added.map(&:last).join] unless added.empty?
          return if @blocking.size > problems

          edits = edits.map { |from, to, added_text| [from, to, added_text.gsub("\n", "\r\n")] } if text.include?("\r\n")
          @proposal = [text, Code.edited(text, edits)]
          taken_out = edits.any? { |from, to, _| to > from }
          plan(@initializer, @proposal.last, 'recipes_paths and config.values') if taken_out ? removable(@initializer) : addable(@initializer)
        end

        # The lines that give the variables of this api, one variable a line.
        # compact: a variable whose code gives nil is not given.
        def entry(indent, unit)
          pairs = @result.expressions.map do |name, code|
            "#{indent}#{unit}#{name}: #{code.match?(SIMPLE_CODE) || code.match?(PLAIN_CODE) ? code : "(#{code})"}"
          end
          "#{indent}#{Snippet.new(@result, @source).key}: { variables: {\n#{pairs.join(",\n")}\n#{indent}}.compact }\n"
        end

        # The edits that give the values: a new config.values, or one more
        # entry in the Hash it is given. That Hash is edited only when the
        # command can read all of it: every key written as a name, none of
        # them this api, and its closing brace alone at the start of a line.
        def values_edits(block, text)
          return [] if @result.expressions.empty?

          config = block.config
          unit = block.indent.include?("\t") ? "\t" : '  '
          given = block.assignments(:values)
          if given.empty?
            return blocked("#{config}.values is assigned where the block does not always run it") if block.assigned_anywhere?(:values)

            return [[block.end_offset, block.end_offset, "#{block.indent}#{config}.values = {\n#{entry("#{block.indent}#{unit}", unit)}#{block.indent}}\n"]]
          end

          hash = given.size == 1 ? given.first.arguments&.arguments&.first : nil
          return blocked("#{config}.values is not given one Hash written between braces: this command does not edit it") unless hash.is_a?(Prism::HashNode)

          keys = hash.elements.map { |element| key_of(element) }
          if keys.include?(:unknown)
            return blocked("#{config}.values has a key that is not written as a name, or a **: this command cannot tell whether #{@result.name} is among them")
          end
          return blocked("#{config}.values already has #{@result.name}: this command does not merge into it") if keys.include?(@result.name)

          closing = hash.closing_loc
          line = text.lines[closing.start_line - 1]
          alone = closing.start_line > hash.opening_loc.start_line && line.b[0...closing.start_column].strip.empty?
          return blocked("#{config}.values is given a Hash whose closing brace does not start a line") unless alone

          indent = line[/\A[ \t]*/]
          start = closing.start_offset - closing.start_column
          last = hash.elements.last
          comma = last && !text.b[last.location.end_offset...start].include?(',') ? [[last.location.end_offset, last.location.end_offset, ',']] : []
          comma + [[start, start, entry("#{indent}#{unit}", unit)]]
        end

        def blocked(reason)
          @blocking << "#{shown(@initializer)}: #{reason}"
          []
        end

        # The name of a key of a Hash, or nil when it is not written.
        def key_of(element)
          return :unknown unless element.is_a?(Prism::AssocNode)

          key = element.key
          key.is_a?(Prism::SymbolNode) || key.is_a?(Prism::StringNode) ? key.unescaped : :unknown
        end

        # The folder of the recipes, from the folder of the file.
        def recipes_glob
          relative = Pathname.new(@directory).relative_path_from(Pathname.new(File.dirname(@initializer))).to_s
          "#{relative}/*#{Internals::Recipe::SUFFIX}"
        end

        def recipes_edits(block)
          given = block.assignments(:recipes_paths)
          if given.empty?
            return blocked("#{block.config}.recipes_paths is assigned where the block does not always run it") if block.assigned_anywhere?(:recipes_paths)

            return [[block.end_offset, block.end_offset, "#{block.indent}#{block.config}.recipes_paths = Dir[File.expand_path('#{recipes_glob}', __dir__)]\n"]]
          end
          return [] if given.all? { |node| node.slice.include?(Internals::Recipe::SUFFIX) && node.slice.include?(File.basename(@directory)) }

          blocked("#{block.config}.recipes_paths is assigned at line #{given.first.location.start_line} in a way this command cannot " \
                  "read: it must give #{@target}")
        end

        # When the old file goes, what names it must go too. The command must
        # be able to read how the project loads its files: apis_files_paths
        # given patterns of Dir, or a list written between brackets, from
        # which the one element that names the file is taken out. Anything
        # else, and any other mention of the file in the code, stops it.
        def files_edits(block, text)
          return [] unless whole_file?

          name = File.basename(@source)
          given = block.assignments(:apis_files_paths)
          if given.empty?
            blocked("#{block.config}.apis_files_paths is not assigned in the block, or only sometimes: this command cannot see how " \
                    "the project loads #{shown(name)}, which would be deleted")
          end
          edits = []
          covered = []
          given.each do |node|
            found = named_in(node.arguments&.arguments&.first, name, text)
            if found.nil?
              blocked("#{block.config}.apis_files_paths is given, at line #{node.location.start_line}, in a way this command cannot " \
                      "read: it cannot tell whether it names #{shown(name)}, which would be deleted")
            elsif found != :none
              edits << found.first
              covered << found.last
            end
          end
          @project.ruby_files.each do |file|
            @project.text(file).to_s.lines.each_with_index do |line, index|
              next unless line.include?(name)
              next if file == @initializer && covered.any? { |lines| lines.cover?(index + 1) }

              @blocking << "#{shown(file)}:#{index + 1} names #{shown(name)}, which would be deleted: take the name out first"
            end
          end
          edits
        end

        # Whether value, given to apis_files_paths, names the file called
        # name. :none when it does not; [edit, lines] to take out the one
        # element that does; nil when the command cannot read value.
        def named_in(value, name, text)
          return :none if pattern?(value)

          if value.is_a?(Prism::CallNode) && value.name == :+ && value.arguments&.arguments&.size == 1
            sides = [named_in(value.receiver, name, text), named_in(value.arguments.arguments.first, name, text)]
            return nil if sides.include?(nil) || sides.count { |side| side != :none } > 1

            return sides.find { |side| side != :none } || :none
          end
          return nil unless value.is_a?(Prism::ArrayNode) && value.opening_loc&.slice == '['
          return nil unless value.elements.all? { |element| written?(element) || pattern?(element.is_a?(Prism::SplatNode) ? element.expression : element) }

          named = value.elements.select { |element| written?(element) && element.slice.include?(name) }
          return :none if named.empty?
          return nil unless named.size == 1

          edit = removal(value, named.first, text)
          edit && [edit, named.first.location.start_line..named.first.location.end_line]
        end

        # Dir['...*...'] or Dir.glob('...*...'): files found when the
        # application starts, not named one by one.
        def pattern?(node)
          node.is_a?(Prism::CallNode) && node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Dir &&
            %i[[] glob].include?(node.name) && node.block.nil? && node.slice.include?('*') && !node.slice.include?('#{')
        end

        # One file named with text only: 'a/b.yml', File.expand_path('a/b.yml', __dir__), Rails.root.join('a', 'b.yml').
        def written?(node)
          return true if node.is_a?(Prism::StringNode)
          return false unless node.is_a?(Prism::CallNode) && %i[expand_path join].include?(node.name) && node.block.nil? && node.arguments

          node.arguments.arguments.all? { |one| one.is_a?(Prism::StringNode) || (one.is_a?(Prism::CallNode) && one.name == :__dir__) }
        end

        # The edit that takes element out of its list, or nil when it shares
        # its lines with something else.
        def removal(list, element, text)
          others = list.elements - [element]
          if list.location.start_line == list.location.end_line
            return [list.location.start_offset, list.location.end_offset, "[#{others.map(&:slice).join(', ')}]"]
          end

          first = element.location.start_line
          last = element.location.end_line
          alone = others.none? { |one| one.location.end_line >= first && one.location.start_line <= last } &&
                  list.opening_loc.start_line < first && list.closing_loc.start_line > last
          return nil unless alone

          lines = text.lines
          from = lines[0...first - 1].sum(&:bytesize)
          [from, from + lines[first - 1..last - 1].sum(&:bytesize), '']
        end

        # ---- verify_with ----

        # A recipe cannot carry verify_with: the one of the api goes on each
        # `api :name` that a class or a module declares, right after what the
        # call is given. When one of them is written in a way the command
        # cannot read, none is changed and the step is left to the person.
        def plan_verify_with
          @result.verify_with.each do |place, method|
            calls = place == 'verify_with' && Internals::Compiler::METHOD_NAME.match?(method.to_s) ? declarations : []
            files = calls.map(&:first).uniq
            unless !calls.empty? && calls.all? { |_, node| readable?(node) } && files.all? { |file| tracked?(file) && File.writable?(full(file)) }
              @left << "#{shown(place)}: was left out of the recipe and could not be written in the code: give it where a class " \
                       "declares the api, as `api :#{@result.name}, verify_with: ...`, or the answers are no longer verified"
              next
            end
            files.each do |file|
              text = text_of(file)
              edits = declarations_in(text).map { |node| [at(node), at(node), ", verify_with: :#{method}"] }
              plan(file, Code.edited(text, edits), 'verify_with on the declaration of the api')
            end
          end
        end

        # Where the arguments of a call end: before its closing parenthesis.
        def at(node) = node.closing_loc ? node.closing_loc.start_offset : node.arguments.location.end_offset

        # [file, node] for each `api :name` of a class or a module that gives
        # no verify_with.
        def declarations(planned: true)
          @project.ruby_files.flat_map do |file|
            text = planned ? text_of(file) : @project.text(file)
            text.to_s.include?('api') ? declarations_in(text).map { |node| [file, node] } : []
          end
        end

        def declarations_in(text)
          tree = Code.tree(text)
          return [] unless tree

          owners = Code.nodes(tree) { |node| node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode) }
          owners.flat_map { |owner| declared_in(owner.body) }.uniq
        end

        # The calls `api :name` in the body of a class or a module: not inside
        # a method, a block or another class, which have a body of their own.
        def declared_in(node, found = [])
          return found if node.nil? || [Prism::DefNode, Prism::BlockNode, Prism::LambdaNode, Prism::ClassNode, Prism::ModuleNode].any? { |kind| node.is_a?(kind) }

          arguments = node.is_a?(Prism::CallNode) && node.name == :api && node.receiver.nil? ? node.arguments&.arguments : nil
          if arguments && arguments.first.is_a?(Prism::SymbolNode) && arguments.first.unescaped == @result.name
            found << node unless options_of(node)&.include?('verify_with')
          end
          node.compact_child_nodes.each { |child| declared_in(child, found) }
          found
        end

        # The names of the options a call gives, or nil when it gives them in
        # a way the command cannot read: a **, a Hash in braces, a block.
        def options_of(node)
          rest = node.arguments.arguments.drop(1)
          return nil unless node.block.nil? && rest.all? { |one| one.is_a?(Prism::KeywordHashNode) }

          keys = rest.flat_map(&:elements).map { |element| element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode) ? element.key.unescaped : nil }
          keys.include?(nil) ? nil : keys
        end

        def readable?(node) = !options_of(node).nil?

        # ---- the old description ----

        def whole_file?
          @whole_file = Convert.shape(File.read(full(@source))).keys == [@result.name] if @whole_file.nil?
          @whole_file
        rescue Refused, Psych::Exception, SystemCallError
          @whole_file = false
        end

        def plan_old_description
          return unless removable(@source)
          return plan(@source, nil, nil) if whole_file?

          text = text_of(@source)
          others = Convert.shape(text)
          lines = text.lines
          start = lines.index { |line| line.match?(/\A(['"]?)#{Regexp.escape(@result.name)}\1:/) }
          finish = start && ((start + 1...lines.size).find { |index| lines[index].match?(/\A\S/) } || lines.size)
          rest = start && (lines[0...start] + lines[finish..]).join
          others.delete(@result.name)
          return plan(@source, rest, "the lines of #{@result.name} are gone") if rest && Convert.shape(rest) == others

          @blocking << "#{shown(@source)} describes other apis too, and the lines of #{@result.name} could not be taken out of it safely"
        rescue Refused, Psych::Exception
          @blocking << "#{shown(@source)} describes other apis too, and the lines of #{@result.name} could not be taken out of it safely"
        end

        # Every Ruby file must still be Ruby with its changes.
        def plan_valid
          @planned.each do |file, text|
            next if text.nil? || !file.match?(Upgrade::Project::RUBY) || Code.tree(text)

            @blocking << "#{shown(file)} would not be valid Ruby after the change"
          end
        end

        # ---- writing ----

        # Installs the recipe and writes every planned text. When a step
        # fails, whatever the reason, every file is put back as it was.
        def apply
          paths = [@target, @lock, *@planned.keys].uniq
          before = paths.to_h { |path| [path, File.exist?(full(path)) ? [File.binread(full(path)), File.stat(full(path)).mode] : nil] }
          made = !File.directory?(full(@directory))
          install
          @planned.each { |file, text| text.nil? ? File.delete(full(file)) : File.write(full(file), text) }
          true
        rescue Exception => e # rubocop:disable Lint/RescueException
          lost = restore(before, made)
          reason = e.is_a?(Refused) ? e.message : e.class.name.split('::').last
          @err.puts "the project could not be changed (#{reason}): " \
                    "#{lost.empty? ? 'every file was put back as it was' : "these files could not be put back: #{lost.map { |path| shown(path) }.join(', ')}"}"
          raise unless e.is_a?(SystemCallError) || e.is_a?(Refused)

          false
        end

        # Returns the paths that could not be put back.
        def restore(before, made)
          lost = before.reject do |path, saved|
            if saved
              File.binwrite(full(path), saved.first)
              File.chmod(saved.last & 0o7777, full(path))
            else
              FileUtils.rm_f(full(path))
            end
            true
          rescue SystemCallError
            false
          end.keys
          Dir.rmdir(full(@directory)) if made && Dir.exist?(full(@directory)) && Dir.empty?(full(@directory))
          lost
        end

        def install
          Dir.mktmpdir do |dir|
            file = File.join(dir, "#{@result.name}#{Internals::Recipe::SUFFIX}")
            File.write(file, @result.text)
            quiet = StringIO.new
            code = Recipes.new(out: quiet, err: quiet, input: StringIO.new).install(file, directory: full(@directory), yes: true)
            raise Refused.new(["#{@target} could not be installed"]) unless code.zero?
          end
        end

        # ---- what is said ----

        def refused
          @err.puts "#{shown(@source)} can become a portable recipe, but the project was not changed:"
          @blocking.each { |reason| @err.puts "  - #{reason}" }
          @err.puts 'Nothing was written.'
          by_hand
          1
        end

        # What the command would have done, as steps with the code to paste.
        def by_hand
          @out.puts '', 'What to do by hand', '', '1. Write the recipe and install it:'
          Code.show(@out, ["bundle exec api_recipes convert #{shown(@source)} --to #{@directory}",
                           "bundle exec api_recipes install #{@target} --yes"], :shell)
          configure_step
          number = 3
          @result.verify_with.each do |place, method|
            next unless place == 'verify_with'

            places = declarations(planned: false).map { |file, node| "#{shown(file)}:#{node.location.start_line}" }
            @out.puts "#{number}. #{places.empty? ? 'Where a class declares the api' : "Where the api is declared (#{places.join(', ')})"}, give verify_with:"
            Code.show(@out, ["api :#{@result.name}, verify_with: #{Internals::Compiler::METHOD_NAME.match?(method.to_s) ? ":#{method}" : '...'}"])
            number += 1
          end
          @out.puts "#{number}. Remove the old description: #{old_description}"
        end

        # The block of ApiRecipes.configure as it is after the change, to put
        # in the place of the one that is there; or, when the command could
        # not work it out, the lines to add.
        def configure_step
          before, after = @proposal && @proposal.map { |text| Code::ConfigureBlock.in(text) }
          if before && after && !Code::UNSAFE.match?(after.lines.join("\n"))
            @out.puts "2. In #{shown(@initializer)}, replace the block of ApiRecipes.configure (lines #{before.first} to #{before.last}) with:"
            return Code.show(@out, after.lines)
          end

          block = @initializer && Code::ConfigureBlock.in(@project.text(@initializer))
          unless block&.config
            @out.puts "2. In #{@initializer ? shown(@initializer) : 'the file that calls ApiRecipes.configure'}, inside the block of ApiRecipes.configure, add:"
            recipes = @initializer ? "Dir[File.expand_path('#{recipes_glob}', __dir__)]" : "Dir['#{@directory}/*#{Internals::Recipe::SUFFIX}']"
            return Code.show(@out, Snippet.new(@result, @source, recipes: recipes).lines)
          end

          recipes = block.assigned_anywhere?(:recipes_paths) ? nil : "Dir[File.expand_path('#{recipes_glob}', __dir__)]"
          snippet = Snippet.new(@result, @source, config: block.config, recipes: recipes)
          values = block.line_of(:values) || (block.assigned_anywhere?(:values) ? 'another line' : nil)
          values = "line #{values}" if values.is_a?(Integer)
          if values && !@result.expressions.empty?
            @out.puts "2. In #{shown(@initializer)}, inside the block of ApiRecipes.configure (line #{block.first}), add this to the Hash that " \
                      "#{block.config}.values is given at #{values}#{', and the line of recipes_paths' if recipes}:"
            Code.show(@out, snippet.entry + (recipes ? ['', "#{block.config}.recipes_paths = #{recipes}"] : []))
          else
            @out.puts "2. In #{shown(@initializer)}, inside the block of ApiRecipes.configure (line #{block.first}), add:"
            Code.show(@out, snippet.lines)
          end
        end

        def old_description
          return "delete #{shown(@source)}" if whole_file?

          lines = File.read(full(@source)).lines
          start = lines.index { |line| line.match?(/\A(['"]?)#{Regexp.escape(@result.name)}\1:/) }
          finish = start && ((start + 1...lines.size).find { |index| lines[index].match?(/\A\S/) } || lines.size)
          "take the lines of #{@result.name} out of #{shown(@source)}#{start ? " (lines #{start + 1} to #{finish})" : ''}"
        end

        def report
          calls = @result.calls
          @out.puts "#{@result.name} #{@result.version} now comes from a portable recipe: #{calls} call#{'s' unless calls == 1}"
          @out.puts '', 'Changed in the project'
          @out.puts "  created  #{@target}, with its line in #{@lock}"
          @planned.each do |file, text|
            @out.puts(text.nil? ? "  deleted  #{shown(file)}" : "  edited   #{shown(file)}: #{@notes[file].compact.join(', and ')}")
          end
          unless @result.changes.empty?
            @out.puts '', 'What changed in the description'
            @result.changes.each { |change| @out.puts "  #{change}" }
          end
          unless @left.empty?
            @out.puts '', 'Left to you'
            @left.each { |one| @out.puts "  - #{one}" }
          end
          @out.puts '', 'Every change is in `git status` and `git diff`. Check the recipes with `api_recipes check`, then start ' \
                        'the application.'
        end
      end
    end
  end
end
