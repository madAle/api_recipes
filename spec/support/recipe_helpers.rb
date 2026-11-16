require 'yaml'
require 'tmpdir'
require 'digest'

# Helpers for the specs of portable recipes. They are methods, not constants:
# a constant of the module is not visible from an example.
module RecipeHelpers
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
