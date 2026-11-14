# frozen_string_literal: true

module ApiRecipes
  module CLI
    # The import command: writes a recipe from an OpenAPI description. The
    # description is read once, from one local file, and nothing in it is run.
    class Import
      # The description cannot be imported. The message says where and why.
      class Error < ApiRecipes::Error; end

      # A value of the description as it is shown in a message: one line of
      # printable characters, cut to a length that keeps the message readable.
      def self.shown(value)
        text = value.to_s.scrub('?').gsub(/[^[:print:]]/, '?')
        "'#{text.length > 80 ? "#{text[0, 80]}..." : text}'"
      end

      # Free text of the description (a title, a description, an operationId)
      # as it may appear in the recipe: one line, without control characters
      # and without the ERB delimiters, which a recipe file would evaluate.
      def self.one_line(value, limit = 200)
        text = value.to_s.scrub('?').gsub(/[[:cntrl:]\s]+/, ' ')
        text = text.gsub(/<%|%>/, '') while text.match?(/<%|%>/)
        text.strip[0, limit]
      end
    end
  end
end

require 'api_recipes/cli/import/document'
require 'api_recipes/cli/import/server'
require 'api_recipes/cli/import/security'
