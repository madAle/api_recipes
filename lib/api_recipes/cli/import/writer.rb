# frozen_string_literal: true

require 'yaml'

module ApiRecipes
  module CLI
    class Import
      # The text of a recipe: the api, its options, the tree of endpoints and a
      # comment beside each operation. Every name and every value is written by
      # Ruby's YAML generator. Before the text is returned it is read back and
      # compared with the data it was written from.
      class Writer
        API_KEYS = %i[protocol host port base_url auth variables].freeze
        ENDPOINT_KEYS = %i[path verb route ok_code].freeze
        COMMENT_COLUMN = 34
        MAX_NAME = 1000
        # Control characters, and the two separators that YAML reads as a new line.
        LINE_BREAKING = /[[:cntrl:]\u2028\u2029]/
        INTERNAL = 'internal error: the recipe does not read back as it was written, so nothing was written'

        # calls: { names of an endpoint => how it is called }, written in a
        # comment under the endpoint; nil to write none.
        def initialize(name:, options:, nodes:, header: nil, calls: nil)
          @name = name
          @options = options
          @nodes = nodes
          @header = header
          @calls = calls
        end

        def to_yaml
          @lines = []
          header = Import.one_line(@header)
          @lines << "# #{header}" unless header.empty?
          data = { @name => api }
          text = "#{@lines.join("\n")}\n"
          raise Error, INTERNAL unless read_back(text) == data

          text
        end

        private

        def read_back(text)
          YAML.safe_load(text)
        rescue Psych::Exception
          raise Error, INTERNAL
        end

        def api
          line(0, "#{scalar(@name, '', 'the name of the api')}:")
          body = {}
          API_KEYS.each do |key|
            body[key.to_s] = value(1, key.to_s, @options[key], "#{@name}.#{key}") if @options.key?(key)
          end
          unless @nodes.empty?
            line(1, 'endpoints:')
            body['endpoints'] = nodes(@nodes, 2, "#{@name}.endpoints")
          end
          body.empty? ? nil : body
        end

        def nodes(list, indent, where, names = [])
          list.to_h do |node|
            name = scalar(node.name, where, 'the name of an endpoint')
            comment = Import.one_line(node.comment)
            line(indent, "#{name}:", comment.empty? ? nil : comment)
            called = names + [node.name.to_s]
            call_line(@calls[called]) if @calls && @calls[called]
            here = "#{where}.#{node.name}"
            body = {}
            ENDPOINT_KEYS.each do |key|
              body[key.to_s] = value(indent + 1, key.to_s, node.options[key], "#{here}.#{key}") if node.options.key?(key)
            end
            unless node.children.empty?
              line(indent + 1, 'endpoints:')
              body['endpoints'] = nodes(node.children, indent + 2, "#{here}.endpoints", called)
            end
            [node.name, body.empty? ? nil : body]
          end
        end

        # Writes key and content, and returns the content as YAML will read it.
        def value(indent, key, content, where)
          key = scalar(key, where, 'a name')
          case content
          when Hash
            if content.empty?
              line(indent, "#{key}: {}")
              {}
            else
              line(indent, "#{key}:")
              content.to_h { |name, item| [name.to_s, value(indent + 1, name.to_s, item, "#{where}.#{name}")] }
            end
          when Array
            line(indent, "#{key}: [#{content.map { |item| scalar(item, where) }.join(', ')}]")
            content
          else
            line(indent, "#{key}: #{scalar(content, where)}")
            content
          end
        end

        # A comment of its own under the line just written, where the comment
        # of that line starts: how the endpoint is called.
        def call_line(call)
          column = @lines.last.index(' # ') || [COMMENT_COLUMN - 1, @lines.last.length].max
          @lines << "#{' ' * column} # #{Import.one_line(call)}"
        end

        def line(indent, text, comment = nil)
          text = "#{'  ' * indent}#{text}"
          text = "#{text.ljust(COMMENT_COLUMN - 1)} # #{comment}" if comment
          @lines << text
        end

        # One name or one plain value as the YAML generator writes it, on one
        # line. Text that a recipe file would run as ERB, or that would start a
        # new line, is refused; the message says where and never shows it.
        def scalar(content, where, what = nil)
          place = [where.empty? ? nil : "#{where}:", what].compact.join(' ')
          if content.is_a?(String)
            raise Error, "#{place} is not valid text" unless content.valid_encoding?
            raise Error, "#{place} contains <%, which a recipe file would run as ERB" if content.include?('<%')
            raise Error, "#{place} contains a control character" if content.match?(LINE_BREAKING)
            # YAML does not read a name longer than 1024 characters.
            raise Error, "#{place} is longer than #{MAX_NAME} characters" if what && content.length > MAX_NAME
          elsif !(content.is_a?(Integer) || content == true || content == false)
            raise Error, INTERNAL
          end
          written = YAML.dump([content], line_width: -1)[/\A---\n- (.*)\n\z/m, 1]
          raise Error, INTERNAL if written.nil? || written.include?("\n")

          written
        end
      end
    end
  end
end
