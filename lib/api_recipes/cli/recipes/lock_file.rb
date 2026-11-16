# frozen_string_literal: true

module ApiRecipes
  module CLI
    class Recipes
      # Writes the recipes.lock of a folder.
      module LockFile
        HEADER = "# Written by api_recipes. Do not edit: change it with `api_recipes install` and `api_recipes update`.\n"
        KEYS = %i[version source commit sha256].freeze

        class << self
          # The text of a lock with these entries: { name => Entry }. Every
          # value is written between single quotes, and the text is read back
          # before it is returned.
          def text(entries)
            lines = entries.sort.flat_map do |name, entry|
              ["  #{quote(name)}:"] + KEYS.filter_map { |key| "    #{key}: #{quote(entry.public_send(key))}" if entry.public_send(key) }
            end
            text = "#{HEADER}format: #{Internals::RecipeLock::FORMAT}\nrecipes:\n#{lines.join("\n")}\n"
            data = Internals::PlainYaml.load(text, max_bytes: Internals::Recipe::MAX_BYTES)
            expected = entries.to_h { |name, entry| [name, entry.to_h.compact.transform_keys(&:to_s)] }
            raise Error, 'internal error: recipes.lock does not read back as it was written' unless (data['recipes'] || {}) == expected

            text
          end

          private

          def quote(value) = "'#{value.to_s.gsub("'", "''")}'"
        end
      end
    end
  end
end
