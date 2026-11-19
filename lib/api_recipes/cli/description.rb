# frozen_string_literal: true

require 'erb'
require 'yaml'

module ApiRecipes
  module CLI
    # A file of a 2.x project that describes apis: YAML, which may hold ERB.
    # The gem no longer loads such a file: the commands read it to check it,
    # to list its calls and to convert it into a portable recipe.
    module Description
      # Returns the apis of the file as { name => description }. ERB is
      # evaluated only with erb: true; without it a file that contains ERB
      # is given to the block, which returns the text to read, or is refused
      # when there is no block. Nothing in it is run.
      def self.read(path, erb: false)
        unless (path.is_a?(String) || path.is_a?(Pathname)) && !path.to_s.include?("\0")
          raise ConfigurationError.new(['every path must be a String or a Pathname, without null bytes'])
        end

        full_path = File.expand_path(path)
        if shared_recipe?(full_path)
          raise RecipeFileError.new(path, 'is a portable recipe (.recipe.yml): it is read as data only')
        end

        text = read_text(path, full_path)
        if erb
          text = ERB.new(text).result
        elsif text.include?('<%')
          unless block_given?
            raise RecipeFileError.new(path, 'contains ERB: run again with --erb to evaluate it ' \
                                            '(this executes the code in the file)')
          end
          text = yield(text)
        end
        data = begin
                 YAML.safe_load(text, permitted_classes: [Symbol], aliases: true)
               rescue Psych::Exception => e
                 raise RecipeFileError.new(path, "invalid YAML: #{e.message}")
               end
        raise RecipeFileError.new(path, 'file is empty') if data.nil?
        raise RecipeFileError.new(path, 'must contain a mapping of api names') unless data.is_a?(Hash)

        Internals::Compiler.normalize(data, :options_map)
      end

      def self.read_text(path, full_path)
        text = File.read(full_path, encoding: 'UTF-8')
        raise RecipeFileError.new(path, 'file is not valid UTF-8') unless text.valid_encoding?

        text
      rescue Errno::ENOENT
        raise RecipeFileError.new(path, 'file not found')
      rescue SystemCallError => e
        raise RecipeFileError.new(path, "cannot read file (#{e.class.name.split('::').last})")
      end

      def self.shared_recipe?(full_path)
        names = [full_path]
        names << File.realpath(full_path) if File.exist?(full_path)
        names.any? { |name| name.downcase.end_with?('.recipe.yml') }
      end
    end
  end
end
