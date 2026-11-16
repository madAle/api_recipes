# frozen_string_literal: true

require 'date'
require 'json'
require 'set'
require 'yaml'

module ApiRecipes
  module CLI
    class Import
      # An OpenAPI 3.0 or 3.1 description read from one local file, YAML or
      # JSON. Only plain data is accepted. A `$ref` is followed when the
      # importer asks for it and only inside the same file: the schemas, which
      # often refer to themselves, are never walked.
      class Document
        SUPPORTED = /\A3\.[01](\.|\z)/
        NOT_YAML = 'the description is not valid YAML'
        MAX_REFS = 64
        READ_PROBLEMS = { Errno::ENOENT => 'no such file', Errno::EISDIR => 'is a directory',
                          Errno::EACCES => 'permission denied' }.freeze

        class << self
          def load(path)
            text = File.read(path, encoding: 'UTF-8')
            raise Error, "#{path}: is not valid UTF-8" unless text.valid_encoding?

            parse(text)
          rescue SystemCallError => e
            raise Error, "#{path}: #{READ_PROBLEMS.fetch(e.class) { "cannot be read (#{e.class.name.split('::').last})" }}"
          end

          def parse(text)
            data = text.lstrip.start_with?('{') ? parse_json(text) : parse_yaml(text)
            raise Error, 'the description is empty' if data.nil?
            raise Error, 'the description must be a mapping' unless data.is_a?(Hash)

            check_version(data)
            new(data)
          end

          private

          # YAML written in flow style starts with a brace too: what is not
          # JSON is read as YAML.
          def parse_json(text)
            JSON.parse(text)
          rescue JSON::ParserError
            begin
              parse_yaml(text)
            rescue Error => e
              raise e unless e.message.start_with?(NOT_YAML)

              raise Error, 'the description is not valid JSON'
            end
          end

          # Dates are the only values beyond plain YAML that a description
          # written by hand contains. Aliases are accepted, since tools write
          # them for repeated parts: an alias is the same object, not a copy,
          # and the importer never expands or prints a mapping or a list. The
          # shape is checked first, on the events of the parser, because Ruby
          # computes the hash of every key: a key that is an alias of a large
          # structure would keep it busy for ever.
          def parse_yaml(text)
            Psych::Parser.new(Shape.new).parse(text)
            YAML.safe_load(text, permitted_classes: [Date, Time], aliases: true)
          rescue Psych::BadAlias
            raise Error, 'the description uses a YAML alias that is not defined'
          rescue Psych::DisallowedClass
            raise Error, 'the description contains something that is not plain data'
          rescue Psych::SyntaxError => e
            raise Error, "#{NOT_YAML} (line #{e.line})"
          end

          def check_version(data)
            if data.key?('swagger')
              raise Error, "Swagger #{Import.text(data['swagger']).to_s[0, 10].gsub(/[^\d.]/, '')} is not supported: " \
                           'convert it to OpenAPI 3 first'
            end
            version = data['openapi']
            return if (version.is_a?(String) || version.is_a?(Numeric)) && SUPPORTED.match?(version.to_s)

            raise Error, 'only OpenAPI 3.0 or 3.1 is supported: the description must say which one in its openapi key'
          end
        end

        # Refuses, while the text is parsed and before any object is built:
        # a key that is not plain text, a nesting that is too deep, binary
        # values, and aliases that together stand for more values than a
        # description can have. Every anchor is given the number of values under
        # it, aliases included, so the count is exact without expanding anything.
        class Shape < Psych::Handler
          MAX_DEPTH = 200
          MAX_ALIASED = 10_000_000
          BINARY = 'tag:yaml.org,2002:binary'

          # One mapping or list that is being read.
          Open = Struct.new(:kind, :children, :anchor, :size)

          def initialize
            super
            @open = []
            @sizes = {}
            @aliased = 0
          end

          def scalar(_value, anchor, tag, *)
            if tag == BINARY
              raise Error, 'the description contains binary data (!!binary): only text is read'
            end

            child(false, 1)
            @sizes[anchor] = 1 if anchor
          end

          # An alias of something still open is a structure that contains itself: it counts as one value.
          def alias(anchor)
            size = @sizes.fetch(anchor, 1)
            @aliased += size
            if @aliased > MAX_ALIASED
              raise Error, 'the aliases of the description stand for more than ten million values: ' \
                           'this is not a description of an api'
            end

            child(true, size)
          end

          def start_mapping(anchor, *) = start(:mapping, anchor)

          def start_sequence(anchor, *) = start(:sequence, anchor)

          def end_mapping = finish

          def end_sequence = finish

          private

          def start(kind, anchor)
            child(true, 0)
            @open << Open.new(kind, 0, anchor, 1)
            raise Error, 'the description is nested too deeply' if @open.size > MAX_DEPTH
          end

          def finish
            done = @open.pop
            @sizes[done.anchor] = done.size if done.anchor
            @open.last.size += done.size if @open.last
          end

          # In a mapping the children come as key, value, key, value.
          def child(composite, size)
            parent = @open.last
            return unless parent

            parent.size += size
            return unless parent.kind == :mapping

            parent.children += 1
            return unless parent.children.odd? && composite

            raise Error, 'a key of the description is an alias, a mapping or a list: keys must be plain text'
          end
        end

        attr_reader :root

        def initialize(root)
          @root = root
        end

        def title = text_of('title')

        def version = text_of('version')

        # node itself, or what its `$ref` points to, through as many `$ref` as
        # it takes. where is the place of node in the description, for messages.
        def resolve(node, where)
          seen = nil
          while node.is_a?(Hash) && node.key?('$ref')
            ref = node['$ref']
            raise Error, "#{where}: $ref must be a string" unless ref.is_a?(String)
            unless ref == '#' || ref.start_with?('#/')
              raise Error, "#{where}: $ref #{Import.shown(ref)} points to another file: " \
                           'bundle the description into one file first'
            end
            raise Error, "#{where}: circular $ref #{Import.shown(ref)}" if seen&.include?(ref)
            raise Error, "#{where}: more than #{MAX_REFS} $ref in a chain" if seen && seen.size >= MAX_REFS

            (seen ||= Set.new) << ref
            node = fetch(ref, where)
          end
          node
        end

        def inspect = "#<#{self.class.name} #{Import.shown(title)}>"

        private

        def text_of(key)
          info = @root['info']
          Import.text(info.is_a?(Hash) ? info[key] : nil)
        end

        # The pieces of a JSON pointer: the %XX of the URL fragment first, then
        # ~1 and ~0.
        def fetch(ref, where)
          pieces = ref.delete_prefix('#').delete_prefix('/').split('/', -1)
          pieces.reduce(@root) do |node, piece|
            piece = piece.gsub(/%\h\h/) { |escape| escape[1, 2].hex.chr }.force_encoding(Encoding::UTF_8)
            child = child_of(node, piece.gsub('~1', '/').gsub('~0', '~'))
            raise Error, "#{where}: $ref #{Import.shown(ref)} does not exist" if child.equal?(MISSING)

            child
          end
        end

        MISSING = Object.new.freeze
        private_constant :MISSING

        def child_of(node, piece)
          case node
          when Hash
            key = node.key?(piece) ? piece : node.each_key.find { |candidate| candidate.to_s == piece }
            key.nil? ? MISSING : node[key]
          when Array
            piece.match?(/\A\d+\z/) && piece.to_i < node.size ? node[piece.to_i] : MISSING
          else
            MISSING
          end
        end
      end
    end
  end
end
