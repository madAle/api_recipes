require 'spec_helper'
require 'api_recipes/cli'

# How each endpoint of an api is called in Ruby: what `import --calls` and
# `convert --calls` write in the comments of a recipe.
describe ApiRecipes::CLI::Calls do
  let(:shop) do
    { shop: { host: 'shop.example.test', variables: { format: {} },
              endpoints: { orders: { endpoints: { show: { path: '/:id' },
                                                   lines: { path: '/:id/lines', endpoints: { show: { path: '/:line' } } } } },
                           stores: { route: false, path: '/stores/:country/:city', endpoints: { open?: nil } },
                           reports: { route: false, endpoints: { monthly: { path: '/{format}/monthly' } } } } } }
  end

  it 'gives the call of every endpoint that can be called, by the names that lead to it' do
    configure_test_apis(shop)
    expect(described_class.of(ApiRecipes.shop.definition)).to eq(
      %w[orders] => '.orders', %w[orders show] => '.orders.show(id)', %w[orders lines] => '.orders.lines(id)',
      %w[orders lines show] => '.orders.lines(id).show(line)', %w[stores open?] => '.stores(country, city).open?',
      %w[reports monthly] => '.reports.monthly'
    )
  end

  it 'gives the call with [] of an endpoint whose name has no method, and of the ones it contains' do
    configure_test_apis(odd: { host: 'odd.example.test',
                               endpoints: { run: { path: '/run/:id', endpoints: { with: nil, show: nil } }, with: nil,
                                            '404': { endpoints: { 'a-b': { path: '/:id' } } }, users: { endpoints: { url: nil } } } })
    calls = described_class.of(ApiRecipes.odd.definition)
    expect(calls).to eq(%w[run] => '.run(id)', %w[run with] => '.run(id)[:with]', %w[run show] => '.run(id).show',
                        %w[with] => '[:with]', %w[404] => '["404"]', %w[404 a-b] => '["404"]["a-b", id]',
                        %w[users] => '.users', %w[users url] => '.users[:url]')
    urls = calls.values.map { |call| ApiRecipes.odd.instance_eval("self#{call.gsub(/\bid\b/, "'x'")}").url.to_s }
    expect(urls).to eq(%w[run/x run/x/with run/x/show with 404 404/x users users/url].map { |path| "https://odd.example.test/#{path}" })
  end

  it 'gives calls that can be made as they are written' do
    configure_test_apis(shop)
    calls = described_class.of(ApiRecipes.shop.definition).values
    shop = ApiRecipes.shop.with(variables: { format: 'pdf' })
    urls = calls.map { |call| shop.instance_eval("self#{call.gsub(/\w+(?=[,)])/, "'x'")}").url.to_s }
    expect(urls).to eq(%w[orders orders/x orders/x/lines orders/x/lines/x stores/x/x/open%3F reports/pdf/monthly]
      .map { |path| "https://shop.example.test/#{path}" })
  end
end
