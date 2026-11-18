# frozen_string_literal: true

module ApiRecipes
  module CLI
    class Upgrade
      # How `upgrade` shows its results: the same sections everywhere, and on
      # a terminal colours, marks and lines that fit its width. The text it
      # is given holds nothing a terminal obeys; it adds only its own marks.
      class Screen
        # The mark and the colour of each kind of finding, the worst first.
        KINDS = { breaks: ['💥', 31], config: ['🧩', 35], check: ['👀', 33] }.freeze
        WIDTHS = (60..110)

        def initialize(out)
          @out = out
          @paint = Code::Paint.on?(out)
          @width = @paint ? width_of(out) : nil
          @blank = true
        end

        def paint? = @paint

        # The title of a section. plain: false leaves it out where there are
        # no colours, for lines that say by themselves what they are.
        def section(mark, title, note = nil, plain: true)
          gap
          return unless @paint || plain

          put(@paint ? "#{mark} #{style(title, 1)}#{note && "  #{style(note, 2)}"}" : title)
          gap if @paint
        end

        # A line of text of a section.
        def line(text)
          @paint ? wrapped(text, '   ', '   ').each { |one| put(one) } : put(text)
        end

        # An entry of a list. What comes before its first colon is what the
        # entry is about.
        def item(text, mark = nil)
          return put("  #{mark || '-'} #{text}") unless @paint

          first = "   #{mark || '•'} "
          wrapped(text, first, ' ' * first.length, bold: text.index(': ') || 0).each { |one| put(one) }
        end

        # A finding, and under it the code that takes the place of the line.
        def finding(kind, where, message, hint = nil)
          if @paint
            mark, colour = KINDS.fetch(kind, ['•', 0])
            put("   #{mark} #{style(kind.to_s.ljust(6), 1, colour)}  #{style(where, 1)}")
            wrapped(message, '      ', '      ').each { |one| put(one) }
          else
            put("#{where}: [#{kind}] #{message}")
          end
          hint ? code(hint) : (gap if @paint)
        end

        # Code to paste, with an empty line before and after it.
        def code(lines, kind = :ruby)
          indent = ' ' * (@paint ? 6 : 4)
          gap
          lines.each { |one| put(one.empty? ? '' : "#{indent}#{@paint ? Code::Paint.public_send(kind, one) : one}") }
          gap
        end

        # What changes in a file: the lines taken out and the lines added,
        # with the lines around them. A character that a terminal would
        # obey is shown as a question mark.
        def diff(file, old, new)
          Diff.hunks(old, new).each do |first, lines|
            gap
            put(@paint ? "   #{style("#{file}:#{first}", 1)}" : "#{file}:#{first}")
            lines.each do |sign, text|
              shown = "#{@paint ? '   ' : ''}#{sign} #{text.gsub(Code::UNSAFE, '?')}".rstrip
              put(@paint ? style(shown, { '-' => 31, '+' => 32 }.fetch(sign, 2)) : shown)
            end
          end
          gap
        end

        # Asks, and tells whether the answer was yes.
        def ask(question, input)
          @out.print(@paint ? "   #{style(question, 1)} [y/N] " : "#{question} [y/N] ")
          @out.flush if @out.respond_to?(:flush)
          answer = input.gets.to_s.strip.downcase
          @blank = false
          %w[y yes].include?(answer)
        end

        # The last line of the results: how many findings, and of which kinds.
        def summary(text, counts)
          gap
          return put(text) unless @paint
          return put("✅ #{style(text, 1, 32)}") if counts.empty?

          worst = KINDS.keys.find { |kind| counts.key?(kind) } || :check
          kinds = KINDS.keys.select { |kind| counts.key?(kind) }.map { |kind| style("#{counts[kind]} #{kind}", KINDS[kind].last) }
          put("#{KINDS[worst].first} #{style(text, 1, KINDS[worst].last)}  #{kinds.join(style(' · ', 2))}")
        end

        # One empty line, and never two.
        def gap
          put('') unless @blank
        end

        private

        def put(text)
          @out.puts(text)
          @blank = text.empty?
        end

        def style(text, *codes) = "\e[#{codes.join(';')}m#{text}\e[0m"

        def width_of(out)
          require 'io/console'
          columns = out.respond_to?(:winsize) ? out.winsize[1].to_i : 0
          columns.zero? ? 80 : columns.clamp(WIDTHS.min, WIDTHS.max)
        rescue StandardError
          80
        end

        # text on lines that fit the width, the first after first and the
        # others after rest, with its first bold characters in bold.
        def wrapped(text, first, rest, bold: 0)
          room = @width - first.length
          lines = []
          text.split(' ').each do |word|
            if lines.empty? || lines.last.length + 1 + word.length > room then lines << word.dup
            else lines.last << ' ' << word
            end
          end
          at = 0
          lines.each_with_index.map do |one, index|
            strong = (bold - at).clamp(0, one.length)
            at += one.length + 1
            "#{index.zero? ? first : rest}#{strong.zero? ? one : "#{style(one[0, strong], 1)}#{one[strong..]}"}"
          end
        end
      end
    end
  end
end
