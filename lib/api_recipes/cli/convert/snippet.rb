# frozen_string_literal: true

module ApiRecipes
  module CLI
    class Convert
      # The code to paste where the command did not write it: the lines for the
      # block of ApiRecipes.configure, with the code of each ERB tag and each
      # value as they are written in the file, so that what is pasted works.
      # Only what a terminal would obey is left out: that value is given as
      # nil, with a comment that says where to copy it from.
      class Snippet
        # What a terminal would obey, or would show in another order.
        UNSAFE = /[^[:print:]\n\t]|[\u200B-\u200F\u202A-\u202E\u2066-\u2069]/
        ENV_ONLY = /\AENV(\[\s*(['"])\w+\2\s*\]|\.fetch\(\s*(['"])\w+\3\s*\))\z/
        PLAIN = /\A("(?:[^"#\\]|\\.)*"|'[^'\\]*'|\d+)\z/

        # config: the name of the block parameter. recipes: the code that
        # gives recipes_paths, or nil when the file assigns it already.
        def initialize(result, source, config: 'config', recipes: "Dir['config/api_recipes/*.recipe.yml']")
          @result = result
          @source = source
          @config = config
          @recipes = recipes
        end

        # The lines to add inside the block.
        def lines
          out = []
          out << "#{@config}.recipes_paths = #{@recipes}" if @recipes
          return out if @result.expressions.empty?

          out + ["#{@config}.values = {", *entry('  '), '}']
        end

        # The lines of this api inside the Hash given to config.values.
        def entry(indent = '')
          names = @result.expressions.keys
          pairs = names.each_with_index.map do |name, index|
            code, comment = value(name)
            "#{indent}  #{name}: #{code}#{',' unless index == names.size - 1}#{" # #{comment}" if comment}"
          end
          ["#{indent}#{key}: { variables: {", *pairs, "#{indent}}.compact }"]
        end

        # The name of the api as a key of a Hash.
        def key
          name = @result.name
          name.match?(/\A[a-z_]\w*\z/) ? name : "\"#{name}\""
        end

        private

        # [code, comment]: the code of the tag, or nil and where to copy from.
        def value(name)
          code = @result.expressions[name]
          ref = @result.refs[name] || {}
          return [ENV_ONLY.match?(code) || PLAIN.match?(code) ? code : "(#{code})", nil] if shown?(code, ref)

          what = ref[:literal] ? 'the value written' : 'the code of the tag'
          where = [ref[:place] && "for #{Recipes::Summary.shown(ref[:place], 100)}", ref[:line] && "at line #{ref[:line]}"].compact.join(', ')
          ['nil', "paste here #{what} #{where} of #{Recipes::Summary.shown(@source, 100)}"]
        end

        # Everything is shown but what would change what the terminal shows.
        def shown?(code, _ref) = !UNSAFE.match?(code)
      end

      # Colours for the code shown on a terminal. The text it is given holds
      # nothing a terminal obeys: Snippet leaves that out.
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
    end
  end
end
