require 'spec_helper'
require 'api_recipes/cli'

describe 'api_recipes routes' do
  let(:recipe) { fixture_openapi('github_small.expected.yml') }

  it 'lists the calls of a recipe in three aligned columns' do
    code, out, err = run_cli('routes', recipe)
    expect([code, err]).to eq([0, ''])
    expect(out.lines.map(&:split)).to eq(
      [%w[github.users GET https://api.github.com/users],
       %w[github.users.show(username) GET https://api.github.com/users/:username],
       %w[github.users.repos(username) GET https://api.github.com/users/:username/repos],
       ['github.repos.issues(owner,', 'repo)', 'GET', 'https://api.github.com/repos/:owner/:repo/issues'],
       ['github.repos.issues(owner,', 'repo).create', 'POST', 'https://api.github.com/repos/:owner/:repo/issues'],
       ['github.repos.issues(owner,', 'repo).show(issue_number)', 'GET',
        'https://api.github.com/repos/:owner/:repo/issues/:issue_number'],
       ['github.repos.issues(owner,', 'repo).update(issue_number)', 'PATCH',
        'https://api.github.com/repos/:owner/:repo/issues/:issue_number']]
    )
    expect(out.lines.map { |line| line.index(/  (GET|POST|PATCH) +https/) }.uniq.size).to eq(1)
    expect(out.lines.map { |line| line.index('https://') }.uniq.size).to eq(1)
  end

  it 'does not list an endpoint that only groups others' do
    _, out, = run_cli('routes', recipe)
    expect(out.lines.map { |line| line.split.first }).not_to include('github.repos')
  end

  it 'shows the variables of the address as they are written' do
    with_description("shop:\n  host: '{shop}.example.test'\n  base_url: v1\n  variables: {shop: {}}\n  endpoints: {orders: }\n", 'shop.yml') do |path|
      code, out, = run_cli('routes', path)
      expect([code, out]).to eq([0, "shop.orders  GET  https://{shop}.example.test/v1/orders\n"])
    end
  end

  it 'reads several files, in the order given' do
    with_description("two:\n  host: two.test\n  endpoints: {ping: }\n", 'two.yml') do |path|
      code, out, = run_cli('routes', path, recipe)
      expect(code).to eq(0)
      expect(out.lines.map { |line| line.split.first[/\A\w+/] }.uniq).to eq(%w[two github])
    end
  end

  it 'prints the output of import as the calls of the design' do
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'github.yml')
      run_cli('import', fixture_openapi('github_small.yml'), '--name', 'github', '--output', target)
      expect(run_cli('routes', target)[1]).to eq(run_cli('routes', recipe)[1])
    end
  end

  it 'evaluates a file with ERB only when asked, and shows a tag as a variable otherwise' do
    with_description("svc:\n  host: <%= 'erb' %>.example.test\n  endpoints: {ping: }\n", 'svc.yml.erb') do |path|
      code, out, err = run_cli('routes', path)
      expect([code, out]).to eq([0, "svc.ping  GET  https://{erb}.example.test/ping\n"])
      expect(err).to match(/svc\.yml\.erb: what an ERB tag gives is shown as \{erb\}/)
      expect(run_cli('routes', path, '--erb')).to eq([0, "svc.ping  GET  https://erb.example.test/ping\n", ''])
    end
  end

  it 'prints the problems of a configuration that is not valid, and exits with 1' do
    with_description("svc:\n  hots: h.test\n  timeout: soon\n", 'bad.yml') do |path|
      code, out, err = run_cli('routes', path, recipe)
      expect(code).to eq(1)
      expect(err).to include('bad.yml: svc: unknown option', 'bad.yml: svc.timeout: must be a positive number')
      expect(out.lines.size).to eq(7)
    end
  end

  it 'prints nothing for a recipe without endpoints' do
    with_description("svc:\n  host: h.test\n", 'empty.yml') do |path|
      expect(run_cli('routes', path)).to eq([0, '', ''])
    end
  end

  it 'exits with 2 for wrong arguments and for a file it cannot read' do
    expect(Dir.mktmpdir { |dir| Dir.chdir(dir) { run_cli('routes') } }.values_at(0, 1)).to eq([2, ''])
    expect(run_cli('routes', recipe, '--bogus').first).to eq(2)
    code, out, err = run_cli('routes', '/nonexistent/recipe.yml', recipe)
    expect(code).to eq(2)
    expect(out.lines.size).to eq(7)
    expect(err).to match(%r{/nonexistent/recipe\.yml: no such file})
    with_description("svc:\n  host: h.test\n", 'locked.yml') do |path|
      File.chmod(0o000, path)
      code, _, err = run_cli('routes', path)
      expect(code).to eq(2)
      expect(err).to match(/locked\.yml: cannot be read/)
    end
  end

  it 'is described by the help' do
    expect(run_cli('--help')[1]).to include('routes [--erb] [FILE]...')
  end

  it 'lists the calls of a portable recipe, read as data only and without its lock' do
    Dir.mktmpdir do |dir|
      path = write_recipe(dir, lock: false)
      code, out, err = run_cli('routes', path)
      expect(code).to eq(0)
      expect(err).to eq('')
      expect(out.lines.map(&:split)).to eq([%w[shop.orders GET https://shop.example.test/orders],
                                            %w[shop.orders.show(id) GET https://shop.example.test/orders/:id],
                                            %w[shop.orders.create POST https://shop.example.test/orders]])
    end
  end

  it 'never evaluates a portable recipe with ERB, even with --erb' do
    Dir.mktmpdir do |dir|
      path = write_recipe(dir, 'shop', "<% raise 'evaluated' %>\n#{recipe_text}", lock: false)
      code, out, err = run_cli('routes', '--erb', path)
      expect(code).to eq(1)
      expect(out).to eq('')
      expect(err).to include('contains <%')
    end
  end
end
