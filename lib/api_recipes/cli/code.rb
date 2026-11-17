# frozen_string_literal: true

module ApiRecipes
  module CLI
    # The code a command gives to paste: how it is shown, and the block of
    # ApiRecipes.configure of a file, which a command gives whole.
    module Code
      # What a terminal would obey, or would show in another order.
      UNSAFE = /[^[:print:]\n\t]|[​-‏‪-‮⁦-⁩]/

      # Colours for the code shown on a terminal. The text it is given holds
      # nothing a terminal obeys.
      module Paint
        RUBY = /('(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")|(#[^\n]*)|(\b[a-z_]\w*:(?!:))|((?<![:\w]):[a-z_]\w*)|(\b[A-Z]\w*)|(\b(?:nil|true|false|do|end)\b)/

        def self.ruby(line)
          line.gsub(RUBY) do
            match = Regexp.last_match
            code = if match[1] then 32
                   elsif match[2] then 2
                   elsif match[3] || match[4] then 36
                   elsif match[5] then 33
                   else 35
                   end
            "\e[#{code}m#{match[0]}\e[0m"
          end
        end

        def self.shell(line) = line.sub(/\A(\S+(?: exec \S+)?)/) { "\e[1m#{Regexp.last_match(1)}\e[0m" }

        # Whether out is a terminal that takes colours.
        def self.on?(out) = out.respond_to?(:tty?) && out.tty? && !ENV.key?('NO_COLOR')
      end

      # Prints a block of code, indented, in colours on a terminal.
      def self.show(out, lines, kind = :ruby)
        paint = Paint.on?(out)
        out.puts
        lines.each { |line| out.puts(line.empty? ? '' : "    #{paint ? Paint.public_send(kind, line) : line}") }
        out.puts
      end

      # Ruby read as a tree, never run. nil when the text is not valid Ruby.
      def self.tree(text)
        require 'prism'
        result = Prism.parse(text)
        result.success? ? result.value : nil
      end

      # Every node of a tree for which the block is true.
      def self.nodes(node, found = [], &wanted)
        return found if node.nil?

        found << node if wanted.call(node)
        node.compact_child_nodes.each { |child| nodes(child, found, &wanted) }
        found
      end

      # text with each [from, to, replacement] applied; from and to count
      # bytes, as the tree does.
      def self.edited(text, edits)
        bytes = text.b
        edits.sort_by { |from, _, _| -from }.each { |from, to, replacement| bytes[from...to] = replacement.b }
        bytes.force_encoding(Encoding::UTF_8)
      end

      # The one call `ApiRecipes.configure do |config| ... end` of a text, read
      # from its tree: a comment or a string that looks like one is not one.
      class ConfigureBlock
        # first, last: the lines of the call and of the end of its block,
        # counted from 1. problem: why the block cannot be edited, or nil.
        attr_reader :config, :first, :last, :problem, :call

        # nil unless text is valid Ruby with exactly one such call.
        def self.in(text)
          tree = text && Code.tree(text)
          calls = tree ? Code.nodes(tree) { |node| configure?(node) } : []
          calls.size == 1 ? new(text, calls.first) : nil
        end

        def self.configure?(node)
          node.is_a?(Prism::CallNode) && node.name == :configure && node.receiver.is_a?(Prism::ConstantReadNode) &&
            node.receiver.name == :ApiRecipes
        end

        def initialize(text, call)
          @text = text
          @lines = text.lines
          @call = call
          block = call.block
          parameters = block.is_a?(Prism::BlockNode) && block.parameters.is_a?(Prism::BlockParametersNode) ? block.parameters.parameters : nil
          names = parameters ? parameters.requireds : []
          @first = call.location.start_line
          @last = block.is_a?(Prism::BlockNode) ? block.closing_loc.start_line : @first
          @config = names.size == 1 && names.first.respond_to?(:name) ? names.first.name.to_s : nil
          @statements = block.is_a?(Prism::BlockNode) && block.body.is_a?(Prism::StatementsNode) ? block.body.body : []
          @problem = problem_of(block)
        end

        # The statements of the block that assign config.name.
        def assignments(name)
          @statements.select do |node|
            node.is_a?(Prism::CallNode) && node.name == :"#{name}=" && node.receiver.is_a?(Prism::LocalVariableReadNode) &&
              node.receiver.name.to_s == @config
          end
        end

        # Whether config.name is assigned anywhere in the block, also where
        # the block does not always run it.
        def assigned_anywhere?(name)
          Code.nodes(@call.block) { |node| node.is_a?(Prism::CallNode) && node.name == :"#{name}=" }.any?
        end

        # The lines where the statements of the block start.
        def statement_lines = @statements.map { |node| node.location.start_line }

        # The line that assigns config.name, counted from 1, or nil.
        def line_of(name) = assignments(name).first&.location&.start_line

        # The indentation of the statements of the block.
        def indent
          line = @statements.empty? ? nil : @lines[@statements.first.location.start_line - 1]
          line ? line[/\A[ \t]*/] : "#{@lines[@last - 1][/\A[ \t]*/]}  "
        end

        # Where a new statement goes: the byte at which the line of the end
        # of the block starts.
        def end_offset = @call.block.closing_loc.start_offset - @call.block.closing_loc.start_column

        # The whole call as lines of text, without the lines numbered in
        # without and with added before its end, indented as the block is.
        def lines(added = [], without: [])
          kept = (@first...@last - 1).reject { |index| without.include?(index + 1) }.map { |index| @lines[index].chomp }
          [@lines[@first - 1].chomp, *kept, *added.map { |line| line.empty? ? '' : "#{indent}#{line}" }, @lines[@last - 1].chomp]
        end

        private

        def problem_of(block)
          return 'is not given a block with do and end' unless block.is_a?(Prism::BlockNode)
          return 'does not take its one parameter, as in `do |config|`' unless @config
          return 'is written on one line' if @first == @last
          return 'has a rescue or an ensure' unless block.body.nil? || block.body.is_a?(Prism::StatementsNode)
          early = Code.nodes(block) { |node| [Prism::NextNode, Prism::BreakNode, Prism::ReturnNode].any? { |kind| node.is_a?(kind) } }
          return 'can end before its last line, with next, break or return' unless early.empty?
          return 'does not end with a line of its own' unless @lines[@last - 1].strip.match?(/\A(end|\})\z/)

          nil
        end
      end
    end
  end
end
