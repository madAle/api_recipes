# frozen_string_literal: true

module ApiRecipes
  module CLI
    class Import
      # One entry of `servers` as the options of an api: protocol, host, port,
      # base_url and variables. Only what differs from the defaults of the gem
      # is returned. A recipe needs a host: one that the description does not
      # give is a variable, which the application gives.
      class Server
        Result = Data.define(:options, :warnings)

        # scheme, authority and path of an address; a query or a fragment is refused before.
        ADDRESS = %r{\A(?:([^:/?#]+):)?(?://([^/?#]*))?([^?#]*)\z}
        VARIABLE = /\{([^{}]*)\}/
        VARIABLE_NAME = /\A[A-Za-z_]\w*\z/
        DEFAULT_PORTS = { 'http' => 80, 'https' => 443 }.freeze

        def self.read(document, index = 0)
          new(document, index).read
        end

        def initialize(document, index)
          @document = document
          @index = index
          @warnings = []
          @names = {}
        end

        def read
          server = chosen
          return Result.new(options: { host: host_variable('the description names no server') }, warnings: @warnings) if server.nil?

          @where = "servers[#{@index}]"
          @declared = server['variables'].is_a?(Hash) ? server['variables'] : {}
          url = server['url']
          raise Error, "#{@where}.url: must be a string" unless url.is_a?(String)
          raise Error, "#{@where}.url: must not have a query or a fragment" if url.match?(/[?#]/)

          scheme, authority, path = ADDRESS.match(url).captures
          options = scheme.nil? && authority.nil? ? relative(path) : absolute(scheme, authority, path)
          Result.new(options: options, warnings: @warnings)
        end

        private

        def chosen
          servers = @document.root['servers']
          servers = [] unless servers.is_a?(Array)
          if servers.empty?
            raise Error, "--server #{@index}: the description names no server" unless @index.zero?

            return nil
          end
          unless @index.between?(0, servers.size - 1)
            raise Error, "--server #{@index}: the description has #{servers.size} servers (0 to #{servers.size - 1})"
          end

          server = @document.resolve(servers[@index], "servers[#{@index}]")
          raise Error, "servers[#{@index}]: must be a mapping" unless server.is_a?(Hash)

          server
        end

        def relative(path)
          options = with_variables({ base_url: base_url(path) }.compact)
          { host: host_variable('the server address is relative') }.merge(options)
        end

        # The variable that stands for the host, named so that it is not one
        # of the variables of the address.
        def host_variable(why)
          taken = @names.values
          name = %w[host api_host].find { |one| !taken.include?(one) }
          name ||= (2..).lazy.map { |number| "api_host_#{number}" }.find { |one| !taken.include?(one) }
          @warnings << "#{why}: the host is the variable {#{name}}, to give with config.values"
          "{#{name}}"
        end

        def absolute(scheme, authority, path)
          protocol = with_defaults(scheme.to_s, 'protocol').downcase
          unless DEFAULT_PORTS.key?(protocol)
            raise Error, "#{@where}.url: protocol #{Import.shown(protocol)} is not supported, only http and https"
          end
          raise Error, "#{@where}.url: must not contain a user or a password" if authority.to_s.include?('@')

          host, port = host_and_port(authority.to_s, protocol)
          raise Error, "#{@where}.url: has no host" if host.empty?

          options = {}
          options[:protocol] = protocol unless protocol == 'https'
          options[:host] = renamed(host)
          options[:port] = port if port
          options[:base_url] = base_url(path)
          with_variables(options.compact)
        end

        # The port is what follows the last colon, unless that colon belongs
        # to an IPv6 address in brackets.
        def host_and_port(authority, protocol)
          match = authority.match(/\A(.*?)(?::([^:\]]*))?\z/)
          host = match[1]
          return [host, nil] if match[2].nil?

          text = with_defaults(match[2], 'port')
          port = text.match?(/\A\d{1,5}\z/) ? text.to_i : 0
          raise Error, "#{@where}.url: the port must be a number from 1 to 65535" unless port.between?(1, 65_535)

          [host, port == DEFAULT_PORTS[protocol] ? nil : port]
        end

        def base_url(path)
          text = renamed(path.to_s).split('/').reject(&:empty?).join('/')
          text.empty? ? nil : text
        end

        # The gem has no variables in the protocol and in the port: there a
        # variable is replaced with its default.
        def with_defaults(text, what)
          text.gsub(VARIABLE) do
            name = Regexp.last_match(1)
            default = @declared[name].is_a?(Hash) ? Import.text(@declared[name]['default']) : nil
            if default.nil?
              raise Error, "#{@where}: the variable #{Import.shown(name)} of the #{what} has no default"
            end

            @warnings << "the variable #{Import.shown(name)} of the #{what} was replaced with its default " \
                         "#{Import.shown(default)}: the gem has no variables there"
            default
          end
        end

        # text with every {name} written with a name the gem accepts.
        def renamed(text)
          text.gsub(VARIABLE) { "{#{name_for(Regexp.last_match(1))}}" }
        end

        def name_for(original)
          @names[original] ||= begin
            name = original.gsub(/\W/, '_')
            name = "_#{name}" unless VARIABLE_NAME.match?(name)
            base = name
            count = 1
            name = "#{base}_#{count += 1}" while @names.value?(name)
            unless name == original
              @warnings << "the server variable #{Import.shown(original)} is written #{Import.shown(name)}: " \
                           'the gem accepts letters, digits and _ in a variable name'
            end
            name
          end
        end

        # Adds the declarations of the variables that host and base_url use,
        # in the order they appear. A variable with no default and no
        # description needs none: the recipe uses it.
        def with_variables(options)
          declared = @names.to_h { |original, name| [name, declaration(original)] }.reject { |_, spec| spec.empty? }
          declared.empty? ? options : options.merge(variables: declared)
        end

        def declaration(original)
          declared = @declared[original]
          unless declared.is_a?(Hash)
            @warnings << "the server variable #{Import.shown(original)} is used and not defined: it has no default"
            return {}
          end
          out = {}
          default = Import.text(declared['default'])
          out['default'] = default unless default.nil?
          description = Import.one_line(declared['description'])
          out['description'] = description unless description.empty?
          out
        end
      end
    end
  end
end
