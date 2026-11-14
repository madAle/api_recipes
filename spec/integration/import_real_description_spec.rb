require 'spec_helper'
require 'api_recipes/cli'
require 'zlib'

# The description of the GitHub REST API (see spec/fixtures/openapi/SOURCE.md):
# 842 paths and 1281 operations, read without any change made by hand.
describe 'Importing the description of a large real API' do
  def with_github_description
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'github.json')
      File.binwrite(path, Zlib::GzipReader.open(fixture_openapi('github.json.gz'), &:read))
      yield path, dir
    end
  end

  it 'writes a recipe that the gem accepts and that offers every operation exactly once' do
    with_github_description do |path|
      code, out, err = run_cli('import', path, '--name', 'github')
      expect(code).to eq(0)
      expect(out).not_to include('<%')
      expect(err.lines.last).to match(/\A1281 operations imported from 842 paths, \d+ warnings\n\z/)

      configure_test_apis(ApiRecipes::Internals::Compiler.normalize(YAML.safe_load(out), :options_map))
      document = ApiRecipes::CLI::Import::Document.load(path)
      expect(routes_as_operations(ApiRecipes.github).sort).to eq(operations_of(document).sort)
      expect(ApiRecipes.github.repos.issues('rails', 'rails').show(1347).url.to_s)
        .to eq('https://api.github.com/repos/rails/rails/issues/1347')
      expect(ApiRecipes.github.users.show('octocat').url.to_s).to eq('https://api.github.com/users/octocat')
    end
  end

  it 'says in the warnings which names it had to change, and nothing else' do
    with_github_description do |path|
      _, _, err = run_cli('import', path, '--name', 'github')
      warnings = err.lines.grep(/\Awarning: /)
      expect(warnings.grep_v(/has two endpoints called|servers given for a path/)).to eq([])
    end
  end

  it 'lists every call of the recipe with routes' do
    with_github_description do |path, dir|
      recipe = File.join(dir, 'github.yml')
      expect(run_cli('import', path, '--name', 'github', '--output', recipe).first).to eq(0)
      code, out, err = run_cli('routes', recipe)
      expect([code, err, out.lines.size]).to eq([0, '', 1281])
      expect(out).to include('github.repos.issues(owner, repo).show(issue_number)')
    end
  end

  it 'takes only the part that is asked for' do
    with_github_description do |path|
      code, out, err = run_cli('import', path, '--name', 'github', '--only', 'repos/{owner}/{repo}/issues*')
      expect(code).to eq(0)
      expect(YAML.safe_load(out).dig('github', 'endpoints').keys).to eq(['repos'])
      expect(err.lines.last).to match(/\A\d+ operations imported from \d+ paths, \d+ left out by the filters/)
    end
  end
end
