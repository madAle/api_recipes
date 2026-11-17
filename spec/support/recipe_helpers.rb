require 'yaml'
require 'tmpdir'
require 'digest'
require 'open3'
require 'fileutils'

# Helpers for the specs of portable recipes. They are methods, not constants:
# a constant of the module is not visible from an example.
module RecipeHelpers
  # What install and update say before git connects to the repository.
  def reading(name = 'shop', address = @repository.address) = "reading #{name} from #{address}\n"

  # The data of a small valid recipe. options are merged over the options of
  # the api, recipe over its `recipe` key; a nil value removes the key.
  def recipe_data(name = 'shop', options = nil, recipe: {}, **more)
    options = (options || {}).merge(more.transform_keys(&:to_s))
    api = {
      'recipe' => { 'name' => name, 'version' => '1.0.0', 'summary' => 'A test api' }.merge(recipe).compact,
      'auth' => { 'type' => 'bearer' },
      'host' => 'shop.example.test',
      'endpoints' => { 'orders' => { 'endpoints' => { 'show' => { 'path' => '/:id' },
                                                       'create' => { 'path' => '', 'verb' => 'post' } } } }
    }
    { name => api.merge(options).compact }
  end

  def recipe_text(...)
    YAML.dump(recipe_data(...))
  end

  # Writes text as the recipe called name in dir and returns the path. With
  # lock: true the recipes.lock of dir gets its entry.
  def write_recipe(dir, name = 'shop', text = recipe_text(name), lock: true, version: '1.0.0')
    path = File.join(dir, "#{name}.recipe.yml")
    File.write(path, text)
    add_to_lock(dir, name, text, version: version) if lock
    path
  end

  def add_to_lock(dir, name, text, version: '1.0.0', **more)
    path = File.join(dir, 'recipes.lock')
    data = File.exist?(path) ? YAML.safe_load(File.read(path)) : { 'format' => 1, 'recipes' => {} }
    data['recipes'][name] = { 'version' => version, 'sha256' => Digest::SHA256.hexdigest(text) }
                            .merge(more.transform_keys(&:to_s))
    File.write(path, YAML.dump(data))
  end

  def read_lock(dir)
    YAML.safe_load(File.read(File.join(dir, 'recipes.lock')))
  end

  def configure_recipes(*paths, **others)
    ApiRecipes.configure do |config|
      config.logger = Logger.new(IO::NULL)
      config.recipes_paths = paths
      others.each { |key, value| config.public_send("#{key}=", value) }
    end
  end
end

# A Git repository of recipes in a folder, for the specs of install and update.
class RecipeRepository
  ENVIRONMENT = { 'GIT_CONFIG_GLOBAL' => File::NULL, 'GIT_CONFIG_NOSYSTEM' => '1',
                  'GIT_AUTHOR_NAME' => 'Test', 'GIT_AUTHOR_EMAIL' => 'test@example.test',
                  'GIT_COMMITTER_NAME' => 'Test', 'GIT_COMMITTER_EMAIL' => 'test@example.test' }.freeze

  attr_reader :directory

  def initialize(directory)
    @directory = directory
    git('init', '--quiet', '--initial-branch=main')
    commit('README.md', "recipes\n")
  end

  def address = "file://#{@directory}"

  def head = git('rev-parse', 'HEAD').strip

  # Commits text as the recipe called name and returns the commit. tag: the
  # version to publish it as, with the tag name-version.
  def publish(name, text, tag: nil)
    commit("recipes/#{name}.recipe.yml", text)
    git('tag', "#{name}-#{tag}") if tag
    head
  end

  def commit(path, content)
    full = File.join(@directory, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    commit_all
  end

  def commit_all
    git('add', '--all')
    git('commit', '--quiet', '--message', 'change')
    head
  end

  def git(*arguments)
    out, err, status = Open3.capture3(ENVIRONMENT, 'git', '-C', @directory, *arguments)
    raise "git #{arguments.first} failed: #{err}" unless status.success?

    out
  end
end

module RecipeHelpers
  # Yields a RecipeRepository. While the block runs, the commands accept
  # file:// addresses and git ignores the configuration of the machine.
  def with_recipe_repository
    git = ApiRecipes::CLI::Recipes::Git
    protocols = git.send(:remove_const, :PROTOCOLS)
    git.const_set(:PROTOCOLS, %w[https file].freeze)
    saved = %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM].to_h { |name| [name, ENV[name]] }
    ENV['GIT_CONFIG_GLOBAL'] = File::NULL
    ENV['GIT_CONFIG_NOSYSTEM'] = '1'
    Dir.mktmpdir { |directory| yield RecipeRepository.new(File.realpath(directory)) }
  ensure
    saved&.each { |name, value| ENV[name] = value }
    if protocols
      git.send(:remove_const, :PROTOCOLS)
      git.const_set(:PROTOCOLS, protocols)
    end
  end
end
