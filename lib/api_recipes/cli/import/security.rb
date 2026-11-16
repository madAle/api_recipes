# frozen_string_literal: true

module ApiRecipes
  module CLI
    class Import
      # The `auth` option of an api, from the global `security` of the
      # description and its `securitySchemes`.
      class Security
        Result = Data.define(:auth, :warnings)

        def self.read(document)
          new(document).read
        end

        def initialize(document)
          @document = document
          @warnings = []
        end

        def read
          components = @document.root['components']
          schemes = components.is_a?(Hash) && components['securitySchemes'].is_a?(Hash) ? components['securitySchemes'] : {}
          global = @document.root['security']
          # A global security that is an empty list says that none is needed.
          auth = if global.is_a?(Array)
                   from_requirements(global, schemes)
                 elsif schemes.size == 1
                   auth_of(schemes.keys.first, schemes)
                 else
                   unless schemes.empty?
                     @warnings << "the description has #{schemes.size} security schemes and no global security: " \
                                  'no auth was written'
                   end
                   nil
                 end
          count_own_security(global)
          Result.new(auth: auth, warnings: @warnings.uniq)
        end

        private

        # The first alternative whose scheme can be written.
        def from_requirements(requirements, schemes)
          requirements.each do |requirement|
            next unless requirement.is_a?(Hash) && !requirement.empty?

            name = requirement.keys.first
            auth = auth_of(name, schemes)
            next unless auth

            if requirement.size > 1
              @warnings << "the security requires several schemes together (#{requirement.keys.map { |key| Import.shown(key) }.join(', ')}): " \
                           "only #{Import.shown(name)} was written"
            end
            return auth
          end
          nil
        end

        def auth_of(name, schemes)
          unless schemes.key?(name)
            @warnings << "the security scheme #{Import.shown(name)} is not defined: no auth was written for it"
            return nil
          end
          scheme = @document.resolve(schemes[name], "components.securitySchemes.#{Import.shown(name)}")
          unless scheme.is_a?(Hash)
            @warnings << "the security scheme #{Import.shown(name)} is not a mapping: no auth was written for it"
            return nil
          end

          case scheme['type']
          when 'http' then http(scheme)
          when 'oauth2', 'openIdConnect' then { 'type' => 'bearer' }
          when 'apiKey' then api_key(scheme)
          else unsupported("the security scheme type #{Import.shown(scheme['type'])}")
          end
        end

        def http(scheme)
          case Import.text(scheme['scheme']).to_s.downcase
          when 'bearer' then { 'type' => 'bearer' }
          when 'basic' then { 'type' => 'basic' }
          else unsupported("the http scheme #{Import.shown(scheme['scheme'])}")
          end
        end

        def api_key(scheme)
          return unsupported('an apiKey in a cookie') if scheme['in'] == 'cookie'
          return unsupported("an apiKey in #{Import.shown(scheme['in'])}") unless %w[header query].include?(scheme['in'])
          return unsupported('an apiKey without a name') unless scheme['name'].is_a?(String) && !scheme['name'].empty?

          { 'type' => scheme['in'], 'name' => scheme['name'] }
        end

        # A path that cannot be read is not counted here: the tree reports it,
        # unless the filters leave it out.
        def path_item(path, item)
          @document.resolve(item, "paths.#{Import.shown(path)}")
        rescue Error
          nil
        end

        # The scheme names of a list of requirements: what two of them are
        # compared by, without walking the whole structure.
        def names_of(requirements)
          return nil unless requirements.is_a?(Array)

          requirements.map { |requirement| requirement.is_a?(Hash) ? requirement.keys.map { |key| Import.text(key) } : nil }
        end

        def unsupported(what)
          @warnings << "#{what} is not supported: no auth was written for it"
          nil
        end

        def count_own_security(global)
          paths = @document.root['paths']
          return unless paths.is_a?(Hash)

          chosen = names_of(global)
          count = paths.sum do |path, item|
            item = path_item(path, item)
            next 0 unless item.is_a?(Hash)

            Tree::METHODS.count do |method|
              operation = item[method]
              operation.is_a?(Hash) && operation.key?('security') && names_of(operation['security']) != chosen
            end
          end
          return if count.zero?

          @warnings << "#{count == 1 ? '1 operation declares its' : "#{count} operations declare their"} own security: " \
                       'the recipe has one auth for the whole api'
        end
      end
    end
  end
end
