require 'forwardable'

module ApiRecipes
  # The result of a request: the http.rb response plus parsed data.
  class Response
    extend Forwardable

    KEY_PATTERN = /\A[a-z_][A-Za-z0-9_]*\z/

    attr_reader :original_response

    # Public instance methods of HTTP::Response (http.rb 6) except request and
    # deconstruct_keys, which would show the request, and uri and inspect,
    # which are defined here.
    def_delegators :@original_response,
                   :body, :charset, :chunked?, :code, :connection, :content_length, :content_type,
                   :cookies, :deconstruct, :flush, :headers, :mime_type, :parse, :proxy_headers,
                   :readpartial, :reason, :status, :to_a, :to_s, :to_str, :version

    def initialize(http_response, mime_type: nil, success: nil, hidden_param: nil)
      @original_response = http_response
      @mime_type = mime_type
      @success = success
      @hidden_param = hidden_param&.to_s
      @parsed = false
    end

    def data
      return @data if @parsed

      @data = @original_response.parse(@mime_type)
      @parsed = true
      @data
    end

    def success?
      return @success unless @success.nil?

      @original_response.status.success?
    end

    def uri
      uri = @original_response.uri
      return uri if @hidden_param.nil? || uri.query.nil?

      kept = uri.query.split('&').reject { |pair| hidden_pair?(pair) }
      uri.dup.tap { |copy| copy.query = kept.empty? ? nil : kept.join('&') }
    end

    def fill(object, only: nil, except: nil)
      only = only && Array(only).map(&:to_sym)
      except = except && Array(except).map(&:to_sym)
      data = self.data
      filled = case data
               when Hash
                 fill_object(object, data, only, except)
               when Array
                 data.map { |element| fill_object(object.new, element, only, except) }
               end
      yield filled, data, status if block_given?
      filled
    end

    def inspect
      "#<#{self.class.name} #{status} #{mime_type}>"
    end

    # The http.rb response holds the request, with its credential: a Response
    # is never serialized.
    def marshal_dump = raise(TypeError, 'an ApiRecipes::Response cannot be serialized')

    def encode_with(_coder) = raise(TypeError, 'an ApiRecipes::Response cannot be serialized')

    private

    def hidden_pair?(pair)
      name = pair.split('=', 2).first.to_s
      name == @hidden_param || URI.decode_www_form_component(name) == @hidden_param
    rescue ArgumentError
      false
    end

    def fill_object(object, attributes, only, except)
      return object unless attributes.is_a?(Hash)

      attributes.each do |key, value|
        key = key.to_s
        next unless KEY_PATTERN.match?(key)
        next if only && !only.include?(key.to_sym)
        next if except&.include?(key.to_sym)
        next unless object.respond_to?("#{key}=")

        object.public_send("#{key}=", value)
      end
      object
    end
  end
end
