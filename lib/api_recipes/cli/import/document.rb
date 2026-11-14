# frozen_string_literal: true

require 'date'
require 'json'
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

          def parse_json(text)
            JSON.parse(text)
          rescue JSON::ParserError
            raise Error, 'the description is not valid JSON'
          end

          # Dates are the only values beyond plain YAML that a description
          # written by hand contains. Aliases are accepted, since tools write
          # them for repeated parts: an alias is the same object, not a copy,
          # and the importer never expands or prints a mapping or a list.
          def parse_yaml(text)
            YAML.safe_load(text, permitted_classes: [Date, Time], aliases: true)
          rescue Psych::BadAlias
            raise Error, 'the description uses a YAML alias that is not defined'
          rescue Psych::DisallowedClass
            raise Error, 'the description contains something that is not plain data'
          rescue Psych::SyntaxError => e
            raise Error, "the description is not valid YAML (line #{e.line})"
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

            (seen ||= []) << ref
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
