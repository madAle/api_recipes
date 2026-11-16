# frozen_string_literal: true

require 'open3'
require 'tmpdir'

module ApiRecipes
  module CLI
    class Recipes
      # Reads the file of one recipe from a Git repository. Nothing is checked
      # out: the commit is fetched into an empty repository in a temporary
      # folder, and the file is read from there after checking that it is a
      # regular file. git is run without a shell, and may only use https and
      # ssh.
      class Git
        PROTOCOLS = %w[https ssh].freeze
        FOLDER = 'recipes'
        FILE_MODES = %w[100644 100755].freeze
        ADDRESS = %r{\A(?<scheme>[a-z]+)://(?<host>[A-Za-z0-9.-]*)(?::[0-9]{1,5})?(?<path>/[A-Za-z0-9._~+/-]*)?\z}
        WITH_USER = %r{\A[A-Za-z][A-Za-z0-9+.-]*://[^/]*@}
        # The two ways git writes an ssh address: ssh://[user@]host[:port]/path
        # and user@host:path. The user, the host and the path never start with
        # a hyphen, which ssh or git would read as an option, and the short
        # form needs its user: host:path alone is also how a mistyped https:/
        # address and a Windows path look.
        SSH_USER = '[A-Za-z0-9_][A-Za-z0-9._-]*'
        SSH_HOST = '[A-Za-z0-9][A-Za-z0-9.-]*'
        SSH_URL = %r{\Assh://(?:#{SSH_USER}@)?#{SSH_HOST}(?::[0-9]{1,5})?/[A-Za-z0-9._~+/-]*\z}
        SSH_SHORT = %r{\A#{SSH_USER}@#{SSH_HOST}:[A-Za-z0-9._~/][A-Za-z0-9._~+/-]*\z}
        WITH_PASSWORD = %r{\Assh://[^/@]*:[^/@]*@}
        ACCEPTED = 'must start with https:// or ssh://, or be written as user@host:path'
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

        # Why the address cannot be used, or nil. An https address with a
        # user name or a password is refused, and so is an ssh one with a
        # password: they would end up in recipes.lock. The user of an ssh
        # address is not a secret and is part of it.
        def self.address_problem(address)
          return 'must be text' unless address.is_a?(String)
          return "must be at most #{MAX_ADDRESS} characters" if address.length > MAX_ADDRESS
          return nil if ssh?(address)
          return 'must not contain a password: ssh takes what it needs from its keys and its agent' if WITH_PASSWORD.match?(address)
          if WITH_USER.match?(address) && !address.start_with?('ssh://')
            return 'must not contain a user name or a password: git takes them from its own configuration'
          end

          match = ADDRESS.match(address)
          return ACCEPTED unless match && match[:scheme] != 'ssh' && PROTOCOLS.include?(match[:scheme])
          return 'must name a host' if match[:host].empty? && match[:scheme] != 'file'

          nil
        end

        # Whether the address is one of the two ssh forms, and ssh may be used.
        def self.ssh?(address)
          PROTOCOLS.include?('ssh') && (SSH_URL.match?(address) || SSH_SHORT.match?(address))
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
          raise Failure, "git could not read #{@address}: #{reason(err)}#{hint(err)}"
        end

        # What to do about a failure that has a known cause, or nothing.
        def hint(err)
          if err.include?('not allowed')
            " (git may use only #{PROTOCOLS.join(' and ')} here: check url.*.insteadOf in your git configuration)"
          elsif err.include?('could not read Username') || err.include?('Authentication failed')
            ' (a private repository needs credentials that git already has for its host, such as a credential ' \
              'helper: the command never asks for them)'
          elsif err.include?('Host key verification failed')
            ' (ssh does not know this host: connect to it once with ssh, or add its key to known_hosts)'
          elsif err.include?('Permission denied')
            ' (ssh has no key that this host accepts for the repository: check the key and the agent with ssh -T)'
          else
            ''
          end
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
          raise Failure, "git failed (#{arguments.find { |argument| !argument.start_with?('-') }}): #{reason(err)}" unless status.success?

          out
        end

        def run(*arguments)
          environment = ENVIRONMENT.merge('GIT_ALLOW_PROTOCOL' => PROTOCOLS.join(':'))
          Open3.capture3(environment, 'git', *arguments, stdin_data: '', binmode: true)
        rescue Errno::ENOENT
          raise Failure, 'git was not found: install git, or install the recipe from a file'
        end

        # Why git failed, as one line that can be printed: the line where it
        # says fatal or error, or the last one.
        def reason(text)
          lines = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub('?').lines.map(&:strip).reject(&:empty?)
          line = lines.reverse.find { |one| one.start_with?('fatal:', 'error:') } || lines.last
          line ? Summary.shown(line) : 'it gave no reason'
        end
      end
    end
  end
end
