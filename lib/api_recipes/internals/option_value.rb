# frozen_string_literal: true

module ApiRecipes
  module Internals
    # The options that are read when a request is sent and can be written with
    # {variables}: protocol, port, timeout, on_bad_code, mime_type, verb and
    # ok_code. The tree keeps what is written; the value is made when the
    # request is built, from the variables of the levels, and is checked for
    # the option it is used as.
    module OptionValue
      KEYS = %i[protocol port timeout on_bad_code mime_type verb ok_code].freeze
      USED_AS = {
        protocol: 'the protocol, which must be http or https',
        port: 'the port, which must be an integer from 1 to 65535',
        timeout: 'the timeout, which must be a positive number',
        on_bad_code: 'on_bad_code, which must be raise or ignore',
        mime_type: 'the mime_type, which must not be empty or contain control characters',
        verb: 'the verb, which must be one known to http.rb',
        ok_code: 'the status that means success, which must be an integer from 100 to 599'
      }.freeze
      CONTROL = /[\x00-\x1F\x7F]/
      WHOLE = /\A\{([A-Za-z_]\w*)\}\z/

      class << self
        # Whether the value of the option key is written with variables.
        def variable?(key, value)
          KEYS.include?(key) && value.is_a?(String) && Template::VARIABLE.match?(value)
        end

        # The name of the variable that gives the whole value, or nil.
        def whole(value)
          match = value.is_a?(String) && WHOLE.match(value)
          match ? match[1].to_sym : nil
        end

        # The value of the option key, with the variables of values filled.
        # What is written without variables is returned as it is. The message
        # of the error names the variable and the option, never the value.
        def resolve(key, value, values, api:)
          return value unless variable?(key, value)

          first = nil
          text = value.gsub(Template::VARIABLE) do
            name = Regexp.last_match(1).to_sym
            first ||= name
            raise MissingVariable.new(api, name) unless values.key?(name)

            values[name].to_s
          end
          made = typed(key, text)
          raise InvalidVariable.new(api, first, "is used as #{USED_AS.fetch(key)}") if made.nil?

          made
        end

        # text as the value of the option key, or nil when it is not one.
        def typed(key, text)
          case key
          when :protocol, :on_bad_code then (key == :protocol ? %w[http https] : %w[raise ignore]).include?(text) ? text.dup.freeze : nil
          when :port then integer(text, 1, 65_535)
          when :ok_code then integer(text, 100, 599)
          when :timeout then number(text)
          when :mime_type then text.empty? || CONTROL.match?(text.b) ? nil : text.dup.freeze
          when :verb
            verb = text.downcase.to_sym if text.match?(/\A[A-Za-z]{1,16}\z/)
            verb && HTTP::Request::METHODS.include?(verb) ? verb : nil
          end
        end

        # The verb as it is shown: in capitals, or as it is written when a
        # variable gives it.
        def shown_verb(verb) = variable?(:verb, verb) ? verb : verb.to_s.upcase

        private

        def integer(text, low, high)
          return nil unless text.match?(/\A[0-9]{1,5}\z/)

          number = text.to_i
          number.between?(low, high) ? number : nil
        end

        def number(text)
          return nil unless text.match?(/\A[0-9]{1,9}(\.[0-9]{1,9})?\z/)

          number = text.include?('.') ? text.to_f : text.to_i
          number.positive? ? number : nil
        end
      end
    end
  end
end
