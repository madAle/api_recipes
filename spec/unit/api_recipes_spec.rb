require 'spec_helper'

describe ApiRecipes do
  it 'has a version number' do
    expect(ApiRecipes::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

# The concurrency examples stop threads on purpose. Every wait has a time
# limit and a thread that raised fails the example with its own error,
# instead of leaving the suite waiting for ever.
def thread_limit = 5

# Waits for a signal on queue. Meant for the main thread: if the thread that
# should send it has died, its error is raised; if it is still running, the
# example fails after the limit.
def await_signal(queue, thread, what)
  return if queue.pop(timeout: thread_limit)

  thread.join(0)
  thread.value unless thread.alive?
  raise "timed out after #{thread_limit} seconds waiting for #{what}"
end

# Waits for the thread to end and re-raises the error that ended it.
def finish_thread(thread, what)
  raise "timed out after #{thread_limit} seconds waiting for #{what} to finish" unless thread.join(thread_limit)

  thread.value
end

# Waits until the thread is blocked or finished.
def await_blocked(thread, what)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + thread_limit
  until thread.stop?
    raise "timed out after #{thread_limit} seconds waiting for #{what} to block" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    Thread.pass
  end
  thread.value unless thread.alive?
end

# Used inside the stopped thread: waits to be resumed, within the limit.
def await_resume(queue)
  raise "the thread was not resumed within #{thread_limit} seconds" unless queue.pop(timeout: thread_limit)
end

  describe '.configure' do
    it 'yields the configuration and defines a method for each api' do
      yielded = nil
      ApiRecipes.configure do |config|
        yielded = config
        config.logger = Logger.new(IO::NULL)
        config.apis_configs = { svc: { host: 'api.example.test', endpoints: { users: nil } }, other: {} }
      end

      expect(yielded).to equal(ApiRecipes.configuration)
      expect(ApiRecipes.svc).to be_a(ApiRecipes::Api)
      expect(ApiRecipes.other).to be_a(ApiRecipes::Api)
    end

    it 'returns the configuration when no block is given' do
      expect(ApiRecipes.configure).to equal(ApiRecipes.configuration)
    end

    it 'returns the same global api at every call' do
      configure_test_apis
      expect(ApiRecipes.svc).to equal(ApiRecipes.svc)
    end

    it 'keeps the previous configuration, unchanged, when a new one fails' do
      ApiRecipes.configure do |config|
        config.logger = Logger.new(IO::NULL)
        config.apis_configs = { svc: { host: 'hash.example.test', endpoints: { users: nil } } }
        config.apis_files_paths = [File.expand_path('../fixtures/svc_override.yml', __dir__)]
      end
      before = ApiRecipes.configuration
      logger = before.logger
      other_logger = Logger.new(IO::NULL)
      # The last one would also reorder the sources of the previous configuration if they were shared.
      failures = [
        ->(config) { config.apis_files_paths = [File.expand_path('../fixtures/missing.yml', __dir__)] },
        ->(config) { config.variables[:svc] = 'not a Hash' },
        ->(config) { config.apis_configs = { svc: { bogus: 1 } } }
      ]
      failures.each do |change|
        expect do
          ApiRecipes.configure do |config|
            config.logger = other_logger
            config.print_urls = true
            change.call(config)
          end
        end.to raise_error(ApiRecipes::ConfigurationError)
        expect(ApiRecipes.configuration).to equal(before)
        expect([before.logger, before.print_urls, before.variables]).to eq([logger, false, {}])
        expect(before.apis_configs.keys).to eq(ApiRecipes.apis)
      end
      ApiRecipes.configure { |config| config.logger = other_logger }
      expect(ApiRecipes.logger).to equal(other_logger)
      expect(ApiRecipes.svc.ping.url.to_s).to eq('https://other.example.test/ping')
    end

    it 'keeps the previous configuration when a failed configure changed what it holds in place' do
      logger = Logger.new(IO::NULL)
      path = File.expand_path('../fixtures/two_apis.yml', __dir__)
      ApiRecipes.configure do |config|
        config.logger = logger
        config.apis_files_paths = [path.dup]
        config.apis_configs = { svc: { host: 'api.example.test', variables: { region: {} },
                                       endpoints: { users: { path: '/people' } } } }
        config.variables = { svc: { region: 'eu' } }
      end
      before = ApiRecipes.configuration
      failures = [
        ->(config) { config.apis_configs[:svc][:bogus] = 1 },
        lambda do |config|
          config.apis_configs[:svc][:endpoints][:users][:path].replace('/evil')
          config.variables[:svc] = 1
        end,
        lambda do |config|
          config.variables[:svc][:region] = 'us'
          config.apis_configs[:svc][:host] = 1
        end,
        ->(config) { config.apis_files_paths.first.replace('missing.yml') }
      ]
      failures.each do |change|
        expect { ApiRecipes.configure { |config| change.call(config) } }.to raise_error(ApiRecipes::ConfigurationError)
      end
      expect(before.apis_configs).to eq(svc: { host: 'api.example.test', variables: { region: {} },
                                               endpoints: { users: { path: '/people' } } })
      expect([before.apis_files_paths, before.variables]).to eq([[path], { svc: { region: 'eu' } }])
      shared = nil
      ApiRecipes.configure { |config| shared = config.logger }
      expect(shared).to equal(logger)
      expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/people')
      expect(ApiRecipes.svc.variables).to eq(region: 'eu')
      expect(ApiRecipes.apis).to contain_exactly(:svc, :billing)
    end
  end

  describe 'concurrent calls' do
    def configure_host(host)
      ApiRecipes.configure do |config|
        config.logger = Logger.new(IO::NULL)
        config.apis_configs = { svc: { host: host, endpoints: { users: nil } } }
      end
    end

    # Runs call in a thread that stops right after the registry method
    # returns, runs other meanwhile, then lets the thread finish.
    def interleave(registry_method, call, other)
      stopped = Queue.new
      resume = Queue.new
      allow(ApiRecipes::Internals::Registry).to receive(registry_method).and_wrap_original do |original, *args, &block|
        result = original.call(*args, &block)
        if Thread.current[:api_recipes_spec_stop]
          stopped << true
          await_resume(resume)
        end
        result
      end
      thread = Thread.new do
        Thread.current[:api_recipes_spec_stop] = true
        call.call
      end
      thread.report_on_exception = false
      await_signal(stopped, thread, 'the thread to stop')
      other.call
      resume << true
      finish_thread(thread, 'the thread')
    end

    it 'pairs the configuration with the registry built from it when two configure calls overlap' do
      interleave(:install, -> { configure_host('one.example.test') }, -> { configure_host('two.example.test') })
      expect(ApiRecipes.svc.users.url.to_s).to eq('https://two.example.test/users')
      expect(ApiRecipes.configuration.apis_configs[:svc][:host]).to eq('two.example.test')
    end

    it 'pairs the configuration with the registry when reset! and configure overlap' do
      configure_host('one.example.test')
      interleave(:reset!, -> { ApiRecipes.reset! }, -> { configure_host('two.example.test') })
      expect(ApiRecipes.apis).to eq([:svc])
      expect(ApiRecipes.configuration.apis_configs.keys).to eq([:svc])
    end
  end

  describe 'reset! and configure with global variables' do
    let(:shopify) { { host: '{shop}.example.test', variables: { shop: {} }, endpoints: { orders: nil } } }

    # Starts configure with a global variable in a thread that stops after the
    # registry is compiled (the lock is held, the variables are not written
    # yet), runs reset! in another thread, lets it reach the lock, then lets
    # configure finish.
    def reset_while_configure_holds_the_lock
      stopped = Queue.new
      resume = Queue.new
      allow(ApiRecipes::Internals::Compiler).to receive(:compile_all).and_wrap_original do |original, *args|
        result = original.call(*args)
        if Thread.current[:api_recipes_spec_stop]
          stopped << true
          await_resume(resume)
        end
        result
      end
      apis = { shopify: shopify }
      configurer = Thread.new do
        Thread.current[:api_recipes_spec_stop] = true
        ApiRecipes.configure do |config|
          config.logger = Logger.new(IO::NULL)
          config.apis_configs = apis
          config.variables = { shopify: { shop: 'old' } }
        end
      end
      configurer.report_on_exception = false
      await_signal(stopped, configurer, 'configure to stop')
      resetter = Thread.new { ApiRecipes.reset! }
      resetter.report_on_exception = false
      await_blocked(resetter, 'reset!')
      resume << true
      finish_thread(configurer, 'configure')
      finish_thread(resetter, 'reset!')
    end

    it 'empties the global variables when reset! runs while configure holds the lock' do
      reset_while_configure_holds_the_lock
      expect(ApiRecipes.apis).to eq([])
      apis = { shopify: shopify }
      ApiRecipes.configure do |config|
        config.logger = Logger.new(IO::NULL)
        config.apis_configs = apis
      end
      expect { ApiRecipes.shopify.orders.url }.to raise_error(ApiRecipes::MissingVariable, /shop/)
    end
  end

  describe '.configuration' do
    it 'is created once' do
      expect(ApiRecipes.configuration).to be_a(ApiRecipes::Configuration)
      expect(ApiRecipes.configuration).to equal(ApiRecipes.configuration)
    end
  end

  describe '.logger' do
    it 'is the logger of the configuration' do
      logger = Logger.new(IO::NULL)
      ApiRecipes.configuration.logger = logger
      expect(ApiRecipes.logger).to equal(logger)
    end
  end
end
