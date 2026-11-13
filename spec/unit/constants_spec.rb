# frozen_string_literal: true

require 'open3'
require 'rbconfig'

RSpec.describe 'constants of the ApiRecipes module' do
  def internal_names
    %w[Request Context Definition Template PathTemplate Compiler Credential Level LevelSet Levels Handles
       Registry Declaration]
  end

  def run_ruby(code)
    lib = File.expand_path('../../lib', __dir__)
    out, err, status = Open3.capture3(RbConfig.ruby, '-I', lib, '-e', code)
    raise "child process failed: #{err}" unless status.success?

    out
  end

  it 'leave the top-level classes of an application visible by their bare name in a class that includes ApiRecipes' do
    code = <<~RUBY
      require 'api_recipes'
      names = #{internal_names.inspect}
      names.each { |name| Object.const_set(name, Class.new) }
      klass = Class.new { include ApiRecipes }
      names.each do |name|
        klass.class_eval("def self.bare = \#{name}")
        puts "\#{name} \#{klass.bare.equal?(Object.const_get(name))}"
      end
    RUBY
    lines = run_ruby(code).lines.map(&:split)
    expect(lines.map(&:first)).to eq(internal_names)
    expect(lines.reject { |_, same| same == 'true' }).to eq([])
  end

  it 'are only the public names and Core' do
    out = run_ruby("require 'api_recipes'; require 'api_recipes/version'; puts ApiRecipes.constants.sort.join(' ')")
    errors = %w[ApiConfigIsNotAnHash ApiNameClashError ConfigurationError CredentialOriginMismatch Error
                InvalidCredential InvalidPathParameter InvalidUrl InvalidVariable MissingVariable NoRouteExists
                PathParamsMismatch RecipeFileError ResponseCodeNotAsExpected UnknownEndpoint]
    expected = errors + %w[Api Endpoint Response Configuration Core VERSION]
    expect(out.split).to eq(expected.sort)
  end
end
