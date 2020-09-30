module ApiRecipes
  class Response

    attr_reader :original_response

    def initialize(response, attributes = {})
      @original_response = response
      @attributes = attributes
    end

    def data
      return @data unless @data.nil?

      @data = @original_response.parse
    end

    def code
      @original_response.status
    end

    def headers
      @original_response.headers
    end
  end
end
