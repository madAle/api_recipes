module ApiRecipes
  # A string with {name} variables, used for the host, the base_url and the
  # header values of an api. How a value is checked depends on the position.
  class Template
    VARIABLE = /\{([A-Za-z_]\w*)\}/
    HOST_VALUE = /\A[A-Za-z0-9._-]+\z/
    CONTROL = /[\x00-\x1F\x7F]/
    POSITIONS = %i[host base_url header].freeze

    def initialize(string, position)
      raise ArgumentError, "unknown template position '#{position}'" unless POSITIONS.include?(position)

      @string = string.to_s.dup.freeze
      @position = position
      @names = @string.scan(VARIABLE).flatten.map(&:to_sym).uniq.freeze
      freeze
    end

    attr_reader :names

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
      case @position
      when :host
        reject(api, name, 'must contain only letters, digits, dots, hyphens and underscores') unless HOST_VALUE.match?(text)
        text
      when :base_url
        reject(api, name, 'must not be blank, "." or ".."') if value.nil? || text.empty? || text == '.' || text == '..'
        PathTemplate.escape(text)
      else
        reject(api, name, 'must not contain control characters') if CONTROL.match?(text)
        text
      end
    end

    def reject(api, name, reason)
      raise InvalidVariable.new(api, name, reason)
    end
  end
end
