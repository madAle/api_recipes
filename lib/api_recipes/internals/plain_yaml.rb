# frozen_string_literal: true

require 'psych'

module ApiRecipes
  module Internals
    # Reads YAML that is only data: mappings with text keys, lists, text,
    # numbers, booleans. What lets a small text say more than it shows, or say
    # one thing to a reader and another to the parser, is refused before any
    # object is built: characters that are not printed, anchors and aliases,
    # tags, the merge key, a key given twice, a key that is not text, a second
    # document, a deep nesting.
    module PlainYaml
      MAX_DEPTH = 100
      # Control and format characters, line and paragraph separators, what is
      # not assigned: what a terminal does not print as it is.
      UNPRINTABLE = /[\p{C}\p{Zl}\p{Zp}]/
      # The same in the text of a file, where a new line and a tab are at home:
      # a comment is text that a person reads too, and the parser takes other
      # characters than a new line as the end of a line.
      HIDDEN = /[\p{Zl}\p{Zp}]|[\p{C}&&[^\n\r\t]]|\r(?!\n)/

      class Refused < Error; end

      # The events of the parser, checked one by one.
      class Shape < Psych::Handler
        Mapping = Struct.new(:keys, :key_next)
        KINDS = { Integer => 'a number', Float => 'a number', TrueClass => 'a boolean', FalseClass => 'a boolean',
                  NilClass => 'nothing' }.freeze

        def initialize
          super
          @stack = []
          @documents = 0
          @scanner = Psych::ScalarScanner.new(Psych::ClassLoader::Restricted.new([], []))
        end

        def start_document(*)
          @documents += 1
          refuse('holds more than one document') if @documents > 1
        end

        def alias(_anchor) = refuse('uses an anchor or an alias')

        def scalar(value, anchor, tag, _plain, quoted, _style)
          check(anchor, tag)
          node(value, quoted)
        end

        def start_mapping(anchor, tag, _implicit, _style)
          check(anchor, tag)
          open(Mapping.new({}, true))
        end

        def start_sequence(anchor, tag, _implicit, _style)
          check(anchor, tag)
          open(:sequence)
        end

        def end_mapping = @stack.pop

        def end_sequence = @stack.pop

        private

        def refuse(reason) = raise(Refused, reason)

        def check(anchor, tag)
          refuse('uses an anchor or an alias') if anchor
          refuse('uses a tag') if tag
        end

        def open(frame)
          node(nil)
          @stack.push(frame)
          refuse("is nested deeper than #{MAX_DEPTH} levels") if @stack.size > MAX_DEPTH
        end

        # A node in its place: a key of the mapping that holds it, or a value.
        # text is nil for a mapping and a list.
        def node(text, quoted = false)
          parent = @stack.last
          return unless parent.is_a?(Mapping)

          key = parent.key_next
          parent.key_next = !key
          return unless key

          refuse('has a key that is not plain text') if text.nil?
          refuse('uses the merge key <<') if text == '<<'
          refuse("the key '#{PlainYaml.label(text)}' is given twice") if parent.keys.key?(text)
          parent.keys[text] = true
          kind = quoted ? nil : kind_of(text)
          refuse("the key '#{PlainYaml.label(text)}' is read as #{kind}, not as text: quote it") if kind
        end

        # What YAML reads an unquoted key as, when that is not text.
        def kind_of(text)
          value = @scanner.tokenize(text)
          value.is_a?(String) ? nil : KINDS.fetch(value.class, 'something else')
        rescue Psych::DisallowedClass
          'something else'
        end
      end

      class << self
        # The data of text, or nil when the text holds none.
        def load(text, max_bytes:)
          raise Refused, "is larger than #{max_bytes} bytes" if text.bytesize > max_bytes
          raise Refused, 'is not valid UTF-8' unless text.encoding == Encoding::UTF_8 && text.valid_encoding?

          hidden = text.index(HIDDEN)
          if hidden
            raise Refused, "line #{text[0, hidden].count("\n") + 1}: contains a character that is not printed " \
                           '(a control or a format character, or a line break that is not a new line)'
          end

          Psych::Parser.new(Shape.new).parse(text)
          Psych.safe_load(text, aliases: false)
        rescue Psych::SyntaxError => e
          raise Refused, "is not valid YAML (line #{e.line})"
        rescue Psych::DisallowedClass => e
          raise Refused, "has a value that is not plain data (#{e.message[/[A-Z]\w*\z/]}): quote it"
        end

        # text as it can be shown: one line, at most limit characters.
        def label(text, limit = 40)
          text.to_s.scrub('?').gsub(UNPRINTABLE, '?')[0, limit]
        end
      end
    end
  end
end
