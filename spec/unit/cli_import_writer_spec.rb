require 'spec_helper'
require 'api_recipes/cli'

describe ApiRecipes::CLI::Import::Writer do
  let(:error) { ApiRecipes::CLI::Import::Error }
  let(:node) { ApiRecipes::CLI::Import::Tree::Node }

  def write(nodes = [], options = { host: 'h.test' }, name: 'svc', header: nil)
    described_class.new(name: name, options: options, nodes: nodes, header: header).to_yaml
  end

  def leaf(name, options = {}, comment = nil, children = []) = node.new(name, options, comment, children)

  it 'writes the options of the api and of the endpoints in a fixed order' do
    options = { variables: { 'shop' => { 'default' => 'acme' }, 'plain' => {} }, auth: { 'type' => 'header', 'name' => 'X-Key' },
                base_url: 'v1', port: 8443, host: '{shop}.example.test', protocol: 'http' }
    nodes = [leaf('users', { ok_code: [200, 202], route: false, verb: 'post', path: '/people' }, nil,
                  [leaf('show', { path: '/:id' })])]
    text = write(nodes, options)
    expect(text).to eq(<<~YAML)
      svc:
        protocol: http
        host: "{shop}.example.test"
        port: 8443
        base_url: v1
        auth:
          type: header
          name: X-Key
        variables:
          shop:
            default: acme
          plain: {}
        endpoints:
          users:
            path: "/people"
            verb: post
            route: false
            ok_code: [200, 202]
            endpoints:
              show:
                path: "/:id"
    YAML
  end

  it 'reads back as the data it was given' do
    nodes = [leaf('a', {}, 'GET /a', [leaf('b', { path: '', verb: 'post', ok_code: 201 }, 'POST /a')]), leaf('c')]
    expect(YAML.safe_load(write(nodes))).to eq(
      'svc' => { 'host' => 'h.test', 'endpoints' => {
        'a' => { 'endpoints' => { 'b' => { 'path' => '', 'verb' => 'post', 'ok_code' => 201 } } }, 'c' => nil
      } }
    )
  end

  it 'writes an api without endpoints and without options' do
    expect(YAML.safe_load(write([], {}))).to eq('svc' => nil)
  end

  it 'puts the comment of an operation beside its name, and none beside a group' do
    nodes = [leaf('users', {}, 'GET /users (users/list)', [leaf('show', { path: '/:id' }, 'GET /users/{id}')]),
             leaf('repos', { route: false })]
    lines = write(nodes).lines.map(&:chomp)
    expect(lines).to include(match(/\A    users: +# GET \/users \(users\/list\)\z/),
                             match(/\A        show: +# GET \/users\/\{id\}\z/), '    repos:')
    expect(lines.grep(/#/).map { |line| line.index('#') }.uniq.size).to eq(1)
  end

  it 'starts with a comment that names the description, when asked' do
    text = write([], { host: 'h.test' }, header: "Generated from Shop API 1.0\nhost: evil.test")
    expect(text.lines.first).to eq("# Generated from Shop API 1.0 host: evil.test\n")
    expect(YAML.safe_load(text)).to eq('svc' => { 'host' => 'h.test' })
  end

  it 'keeps names that YAML would read as something else' do
    names = %w[on no yes off null true false 404 1.5 ~ 2024-01-01 a:b]
    text = write(names.map { |name| leaf(name) }, {}, name: 'no')
    expect(YAML.safe_load(text)).to eq('no' => { 'endpoints' => names.to_h { |name| [name, nil] } })
  end

  it 'keeps a comment on one line, without ERB and without growing' do
    comment = "GET /a\nhost: evil.test\r\n<%= raise 'x' %> # more #{'z' * 500}"
    text = write([leaf('a', {}, comment)])
    expect(text.lines.size).to eq(4)
    expect(text).not_to match(/<%|%>/)
    expect(text.lines.map(&:length).max).to be < 260
    expect(YAML.safe_load(text)).to eq('svc' => { 'host' => 'h.test', 'endpoints' => { 'a' => nil } })
  end

  it 'refuses ERB in a value or in a name, and says where' do
    expect { write([leaf('a', { path: "/x<%= 1 %>" })]) }.to raise_error(error, /svc\.endpoints\.a\.path: contains <%/)
    expect { write([leaf('a<%b')]) }.to raise_error(error, /svc\.endpoints: .*contains <%/)
    expect { write([], { host: '<%= 1 %>.test' }) }.to raise_error(error, /svc\.host: contains <%/)
    expect { write([], { auth: { 'type' => 'header', 'name' => '<%x%>' } }) }.to raise_error(error, /svc\.auth\.name: contains <%/)
    expect { write([], { variables: { 'shop' => { 'default' => '<% exit %>' } } }) }
      .to raise_error(error, /svc\.variables\.shop\.default: contains <%/)
    expect { write([], {}, name: 'a<%') }.to raise_error(error, /contains <%/)
  end

  it 'refuses a control character in a value or in a name, and says where' do
    expect { write([leaf('a', { path: "/x\nhost: evil.test" })]) }
      .to raise_error(error, /svc\.endpoints\.a\.path: contains a control character/)
    expect { write([leaf("a\nb")]) }.to raise_error(error, /control character/)
    expect { write([], { host: "h.test\0" }) }.to raise_error(error, /svc\.host: contains a control character/)
  end

  it 'never shows the value it refuses' do
    expect { write([], { host: "SECRET<%\n" }) }.to raise_error(error) { |e| expect(e.message).not_to include('SECRET') }
  end
end
