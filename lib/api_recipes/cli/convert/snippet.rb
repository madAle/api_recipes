# frozen_string_literal: true

module ApiRecipes
  module CLI
    class Convert
      # The code to paste where the command did not write it: the lines for the
      # block of ApiRecipes.configure, with the code of each ERB tag and each
      # value as they are written in the file, so that what is pasted works.
      # Only what a terminal would obey is left out: that value is given as
      # nil, with a comment that says where to copy it from.
      class Snippet
        ENV_ONLY = /\AENV(\[\s*(['"])\w+\2\s*\]|\.fetch\(\s*(['"])\w+\3\s*\))\z/
        PLAIN = /\A("(?:[^"#\\]|\\.)*"|'[^'\\]*'|\d+)\z/

        # config: the name of the block parameter. recipes: the code that
        # gives recipes_paths, or nil when the file assigns it already.
        def initialize(result, source, config: 'config', recipes: "Dir['config/api_recipes/*.recipe.yml']")
          @result = result
          @source = source
          @config = config
          @recipes = recipes
        end

        # The lines to add inside the block.
        def lines
          out = []
          out << "#{@config}.recipes_paths = #{@recipes}" if @recipes
          return out if @result.expressions.empty?

          out + ["#{@config}.values = {", *entry('  '), '}']
        end

        # The lines of this api inside the Hash given to config.values.
        def entry(indent = '')
          names = @result.expressions.keys
          pairs = names.each_with_index.map do |name, index|
            code, comment = value(name)
            "#{indent}  #{name}: #{code}#{',' unless index == names.size - 1}#{" # #{comment}" if comment}"
          end
          ["#{indent}#{key}: { variables: {", *pairs, "#{indent}}.compact }"]
        end

        # The name of the api as a key of a Hash.
        def key
          name = @result.name
          name.match?(/\A[a-z_]\w*\z/) ? name : "\"#{name}\""
        end

        private

        # [code, comment]: the code of the tag, or nil and where to copy from.
        def value(name)
          code = @result.expressions[name]
          ref = @result.refs[name] || {}
          return [ENV_ONLY.match?(code) || PLAIN.match?(code) ? code : "(#{code})", nil] if shown?(code, ref)

          what = ref[:literal] ? 'the value written' : 'the code of the tag'
          where = [ref[:place] && "for #{Recipes::Summary.shown(ref[:place], 100)}", ref[:line] && "at line #{ref[:line]}"].compact.join(', ')
          ['nil', "paste here #{what} #{where} of #{Recipes::Summary.shown(@source, 100)}"]
        end

        # Everything is shown but what would change what the terminal shows.
        def shown?(code, _ref) = !Code::UNSAFE.match?(code)
      end
    end
  end
end
