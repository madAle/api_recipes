# frozen_string_literal: true

module ApiRecipes
  module CLI
    # The ERB tags of a file that is read without running its code.
    module Tags
      COMMENT = /<%#.*?%>/m
      OUTPUT = /<%=.*?%>/m

      # text with each output tag replaced by mark and each comment tag
      # removed; nil when another tag is left, which can decide the lines the
      # file has.
      def self.replaced(text, mark)
        plain = text.gsub(COMMENT, '').gsub(OUTPUT, mark)
        plain.gsub('<%%', '').include?('<%') ? nil : plain.gsub('<%%', '<%')
      end
    end
  end
end
