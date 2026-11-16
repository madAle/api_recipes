# frozen_string_literal: true

require 'open3'
require 'tmpdir'

module ApiRecipes
  module CLI
    class Recipes
      # Reads the file of one recipe from a Git repository. Nothing is checked
      # out: the commit is fetched into an empty repository in a temporary
      # folder, and the file is read from there after checking that it is a
      # regular file. git is run without a shell, and may only use https.
      class Git
        PROTOCOLS = %w[https].freeze
        FOLDER = 'recipes'
        FILE_MODES = %w[100644 100755].freeze
        ADDRESS = %r{\A(?<scheme>[a-z]+)://(?<host>[A-Za-z0-9.-]*)(?::[0-9]{1,5})?(?<path>/[A-Za-z0-9._~+/-]*)?\z}
        WITH_USER = %r{\A[A-Za-z][A-Za-z0-9+.-]*://[^/]*@}
        MAX_ADDRESS = 2000
        COMMIT = /\A(?:\h{40}|\h{64})\z/
        # git asks nothing, reads pathspecs as they are written, answers in
        # English, and does not take a repository from the environment.
        ENVIRONMENT = { 'GIT_TERMINAL_PROMPT' => '0', 'GIT_LITERAL_PATHSPECS' => '1', 'LC_ALL' => 'C',
                        'GIT_DIR' => nil, 'GIT_WORK_TREE' => nil, 'GIT_INDEX_FILE' => nil, 'GIT_NAMESPACE' => nil,
                        'GIT_OBJECT_DIRECTORY' => nil, 'GIT_ALTERNATE_OBJECT_DIRECTORIES' => nil,
                        'GIT_COMMON_DIR' => nil }.freeze

        # git is missing or could not do its work.
        class Failure < Error; end

        # The repository was read, and the recipe is not there.
        class NotFound < Error; end

        Found = Data.define(:text, :commit)

        # Why the address cannot be used, or nil. An address with a user name
        # or a password is refused: it would end up in recipes.lock.
        def self.address_problem(address)
          return 'must be text' unless address.is_a?(String)
          return "must be at most #{MAX_ADDRESS} characters" if address.length > MAX_ADDRESS
          if WITH_USER.match?(address)
            return 'must not contain a user name or a password: git takes them from its own configuration'
          end

          match = ADDRESS.match(address)
          return "must start with #{PROTOCOLS.first}://" unless match && PROTOCOLS.include?(match[:scheme])
          return 'must name a host' if match[:host].empty? && match[:scheme] != 'file'

          nil
        end

        def initialize(address)
          problem = self.class.address_problem(address)
          raise Failure, "the address of the repository #{problem}" if problem

          @address = address
        end

        # The recipe called name: at the tag name-version, or at the head of
        # the repository when version is nil.
        def fetch(name, version = nil)
          unless Recipe::NAME.match?(name) && (version.nil? || Recipe::VERSION.match?(version))
            raise ArgumentError, 'not the name or the version of a recipe'
          end

          Dir.mktmpdir('api_recipes') do |directory|
            git('init', '--bare', '--quiet', '--template=', directory)
            fetch_commit(directory, name, version)
            commit = git("--git-dir=#{directory}", 'rev-parse', '--verify', '--quiet', 'FETCH_HEAD^{commit}').strip
            raise Failure, "git did not say which commit of #{@address} it read" unless COMMIT.match?(commit)

            Found.new(text: file(directory, commit, name), commit: commit)
          end
        end

        private

        def fetch_commit(directory, name, version)
          ref = version ? "refs/tags/#{name}-#{version}" : 'HEAD'
          _out, err, status = run("--git-dir=#{directory}", *transport, 'fetch', '--depth', '1', '--no-tags',
                                  '--no-recurse-submodules', '--quiet', '--', @address, ref)
          return if status.success?

          if version && err.include?("couldn't find remote ref")
            raise NotFound, "version #{version} of #{name} is not in #{@address}: there is no tag #{name}-#{version}"
          end
          raise Failure, "git could not read #{@address}: #{last_line(err)}"
        end

        # Only the protocols of PROTOCOLS, whatever the configuration of git
        # says; no redirect to another address; objects checked on arrival.
        def transport
          allowed = PROTOCOLS.flat_map { |protocol| ['-c', "protocol.#{protocol}.allow=always"] }
          ['-c', 'protocol.allow=never', *allowed, '-c', 'http.followRedirects=false', '-c', 'transfer.fsckObjects=true',
           '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=30']
        end

        def file(directory, commit, name)
          path = "#{FOLDER}/#{name}#{Recipe::SUFFIX}"
          entry = git("--git-dir=#{directory}", 'ls-tree', '-z', commit, '--', path).split("\0").first
          raise NotFound, "#{name} is not in #{@address}: there is no #{path}" if entry.nil?

          mode, type, id = entry.split("\t", 2).first.split
          unless FILE_MODES.include?(mode) && type == 'blob' && COMMIT.match?(id.to_s)
            raise NotFound, "#{path} in #{@address} is not a regular file (it is a link, a folder or a submodule): it was not read"
          end
          size = git("--git-dir=#{directory}", 'cat-file', '-s', id).strip
          unless size.match?(/\A[0-9]{1,12}\z/) && size.to_i <= Recipe::MAX_BYTES
            raise NotFound, "#{path} in #{@address} is larger than #{Recipe::MAX_BYTES} bytes: it was not read"
          end

          git("--git-dir=#{directory}", 'cat-file', 'blob', id).force_encoding(Encoding::UTF_8)
        end

        # The output of a git command that must succeed.
        def git(*arguments)
          out, err, status = run(*arguments)
          raise Failure, "git failed (#{arguments.find { |argument| !argument.start_with?('-') }}): #{last_line(err)}" unless status.success?

          out
        end

        def run(*arguments)
          environment = ENVIRONMENT.merge('GIT_ALLOW_PROTOCOL' => PROTOCOLS.join(':'))
          Open3.capture3(environment, 'git', *arguments, stdin_data: '', binmode: true)
        rescue Errno::ENOENT
          raise Failure, 'git was not found: install git, or install the recipe from a file'
        end

        # What git said last, as one line that can be printed.
        def last_line(text)
          line = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub('?').lines.map(&:strip).reject(&:empty?).last
          line ? Summary.shown(line) : 'it gave no reason'
        end
      end
    end
  end
end
