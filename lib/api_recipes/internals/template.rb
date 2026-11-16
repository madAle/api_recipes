# frozen_string_literal: true

module ApiRecipes
  module Internals
    # A string with {name} variables, used for the host, the base_url and the
    # values of the headers and of the query parameters sent with every request.
    # How a value is checked depends on the position.
    class Template
      VARIABLE = /\{([A-Za-z_]\w*)\}/
      HOST_VALUE = /\A[A-Za-z0-9._-]+\z/
      CONTROL = /[\x00-\x1F\x7F]/
      POSITIONS = %i[host base_url header param].freeze

      # value as one segment of a path: what base_url and the path of an
      # endpoint do with the value of a variable.
      def self.segment(value, name, api)
        text = value.to_s
        if value.nil? || text.empty? || text == '.' || text == '..'
          raise InvalidVariable.new(api, name, 'must not be blank, "." or ".."')
        end

        PathTemplate.escape(text)
      end

      def initialize(string, position)
        raise ArgumentError, "unknown template position '#{position}'" unless POSITIONS.include?(position)

        @string = string.to_s.dup.freeze
        @position = position
        @names = @string.scan(VARIABLE).flatten.map(&:to_sym).uniq.freeze
        freeze
      end

      attr_reader :names

      # Shows the variable names only: the string can hold a secret.
      def inspect
        "#<#{self.class} #{@position} variables: #{@names.empty? ? 'none' : @names.join(', ')}>"
      end

      def pretty_print(printer)
        printer.text(inspect)
      end

      def static?
        @names.empty?
      end

      def to_s
        @string
      end

      def expand(values, api:)
        @string.gsub(VARIABLE) do
          name = Regexp.last_match(1).to_sym
          raise MissingVariable.new(api, name) unless values.key?(name)

          encode(values[name], name, api)
        end
      end

      private

      def encode(value, name, api)
        text = value.to_s
        bytes = text.b
        case @position
        when :host
          reject(api, name, 'must contain only letters, digits, dots, hyphens and underscores') unless HOST_VALUE.match?(bytes)
          text
        when :base_url then self.class.segment(value, name, api)
        # http.rb encodes the name and the value of a query parameter.
        when :param then text
        else
          reject(api, name, 'must not contain control characters') if CONTROL.match?(bytes)
          text
        end
      end

      def reject(api, name, reason)
        raise InvalidVariable.new(api, name, reason)
      end
    end
  end
end
