module ApiRecipes
  # The `path` of one endpoint, parsed once. Fixed text is percent-encoded at
  # parse time; placeholder values are encoded at expand time.
  class PathTemplate
    NAME = /[A-Za-z_]\w*/
    FIXED_KEPT = /\A(?:[A-Za-z0-9\-._~!$&'()*+,;=:@\/]|%\h\h)/
    UNRESERVED = /[A-Za-z0-9\-._~]/

    # Percent-encodes every byte outside letters, digits and -._~
    def self.escape(string)
      string.to_s.each_byte.map do |byte|
        char = byte.chr
        char.match?(UNRESERVED) ? char : format('%%%02X', byte)
      end.join
    end

    def self.parse(string)
      new(string.to_s).freeze
    end

    def initialize(string)
      @parts = parse_parts(string).freeze
      names = @parts.select { |kind, _| kind != :text }.map(&:last)
      repeated = names.find { |name| names.count(name) > 1 }
      raise ArgumentError, "placeholder '#{repeated}' is repeated in '#{string}'" if repeated
      @param_names = names.freeze
    end

    attr_reader :param_names

    # The block, if given, is called with the name of a parameter and :slash
    # when its value (not a splat) contains '/', or :encoded when it contains a
    # sequence %XX. It never receives the value.
    def expand(values, endpoint:, &block)
      remaining = values.dup
      @parts.map do |kind, content|
        case kind
        when :text then content
        when :param then encode_value(remaining.shift, content, endpoint, &block)
        when :splat then encode_splat(remaining.shift, content, endpoint, &block)
        end
      end.join
    end

    def to_s
      @parts.map do |kind, content|
        case kind
        when :text then content
        when :param then ":#{content}"
        when :splat then "*#{content}"
        end
      end.join
    end

    private

    def parse_parts(string)
      parts = []
      text = +''
      index = 0
      while index < string.length
        rest = string[index..]
        segment_start = index.zero? || string[index - 1] == '/'
        if rest.start_with?('\\:')
          text << ':'
          index += 2
        elsif (match = rest.match(/\A:(#{NAME})/o))
          flush(parts, text)
          parts << [:param, match[1].to_sym]
          index += match[0].length
        elsif segment_start && (match = rest.match(/\A\*(#{NAME})/o))
          flush(parts, text)
          parts << [:splat, match[1].to_sym]
          index += match[0].length
        elsif (match = rest.match(FIXED_KEPT))
          text << match[0]
          index += match[0].length
        else
          text << self.class.escape(rest[0])
          index += 1
        end
      end
      flush(parts, text)
      parts
    end

    def flush(parts, text)
      return if text.empty?
      parts << [:text, text.dup.freeze]
      text.clear
    end

    def encode_splat(value, name, endpoint, &block)
      raise InvalidPathParameter.new(endpoint, name, 'is nil') if value.nil?
      pieces = value.to_s.b.split('/', -1)
      pieces = [''] if pieces.empty?
      pieces.map { |piece| encode_value(piece, name, endpoint, &block) }.join('/')
    end

    def encode_value(value, name, endpoint)
      raise InvalidPathParameter.new(endpoint, name, 'is nil') if value.nil?
      string = value.to_s
      raise InvalidPathParameter.new(endpoint, name, 'is empty') if string.empty?
      raise InvalidPathParameter.new(endpoint, name, 'is a dot segment') if string == '.' || string == '..'
      if block_given?
        yield name, :slash if string.b.include?('/')
        yield name, :encoded if string.b.match?(/%\h\h/)
      end
      self.class.escape(string)
    end
  end
end
