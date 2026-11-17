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

      # The one block `ApiRecipes.configure do |config| ... end` of a text.
      class ConfigureBlock
        PATTERN = /^([ \t]*)ApiRecipes\.configure do \|([a-z_]\w*)\|[ \t]*$/

        # first, last: the lines of `do` and of `end`, counted from 1.
        attr_reader :indent, :config, :first, :last

        # nil unless text has exactly one such block, with its end.
        def self.in(text)
          return nil unless text && text.scan(PATTERN).size == 1

          lines = text.lines
          start = lines.index { |line| PATTERN.match?(line) }
          indent, config = PATTERN.match(lines[start]).captures
          finish = (start + 1...lines.size).find { |index| lines[index].match?(/\A#{Regexp.escape(indent)}end[ \t]*\r?\n?\z/) }
          finish && new(lines, start, finish, indent, config)
        end

        def initialize(lines, start, finish, indent, config)
          @lines = lines
          @indent = indent
          @config = config
          @first = start + 1
          @last = finish + 1
        end

        # The lines between do and end, each with its number.
        def body = (@first...@last - 1).map { |index| [index + 1, @lines[index].chomp] }

        # The line that assigns config.name, counted from 1, or nil.
        def line_of(name) = body.find { |_, line| line.match?(/\A\s*#{@config}\.#{name}\b/) }&.first

        # The whole block as text lines, without the lines numbered in
        # without and with added before its end, indented as the body is.
        def lines(added = [], without: [])
          kept = body.reject { |number, _| without.include?(number) }.map(&:last)
          [@lines[@first - 1].chomp, *kept, *added.map { |line| line.empty? ? '' : "#{@indent}  #{line}" }, @lines[@last - 1].chomp]
        end
      end
    end
  end
end
