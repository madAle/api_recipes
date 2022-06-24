module ApiRecipes
  class Response

    attr_reader :original_response

    def initialize(response, attributes = {})
      @original_response = response
      @attributes = attributes
    end

    def data
      return @data unless @data.nil?

      # TODO: rescue nil?
      @data = @original_response.parse @attributes[:mime_type]
    end

    # Forward method calls to 'original' Response class
    def method_missing(symbol, *args, &block)
      @original_response.send symbol,* args, &block
    end
  end
end
