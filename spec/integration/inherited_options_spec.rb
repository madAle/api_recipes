require 'spec_helper'

describe 'Options that go down the tree' do
  let(:json) { { 'Content-Type' => 'application/json' } }

  # things > part > leaf, and other next to things.
  def configure(things = {}, part = {}, leaf = {}, api = {})
    tree = things.merge(endpoints: { part: part.merge(endpoints: { leaf: leaf }) })
    configure_test_apis(svc: { host: 'api.example.test' }.merge(api).merge(endpoints: { things: tree, other: nil }))
    ApiRecipes.svc
  end

  def respond(path, status: 200, body: '{}', headers: json)
    stub_request(:get, "#{base_url}#{path}").to_return(status: status, body: body, headers: headers)
  end

  describe 'timeout' do
    before { respond('/things/part/leaf') }

    it 'comes from the endpoint above' do
      svc = configure({}, { timeout: 7 })
      expect_timeout(7)
      svc.things.part.leaf.run
    end

    it 'comes from the nearest endpoint above that has one' do
      svc = configure({ timeout: 9 }, {}, {}, timeout: 20)
      expect_timeout(9)
      svc.things.part.leaf.run
    end

    it 'is the one of the endpoint itself when it has one' do
      svc = configure({ timeout: 9 }, { timeout: 7 }, { timeout: 2 })
      expect_timeout(2)
      svc.things.part.leaf.run
    end

    it 'is the one of the api when no endpoint above has one' do
      svc = configure({}, {}, {}, timeout: 20)
      expect_timeout(20)
      svc.things.part.leaf.run
    end

    it 'does not reach an endpoint that is not below' do
      svc = configure({ timeout: 9 })
      respond('/other')
      expect_timeout(3)
      svc.other.run
    end

    it 'wins over with on the api' do
      svc = configure({ timeout: 9 })
      expect_timeout(9)
      svc.with(timeout: 30).things.part.leaf.run
    end

    it 'loses to with on the endpoint' do
      svc = configure({ timeout: 9 })
      expect_timeout(40)
      svc.things.part.leaf.with(timeout: 40).run
    end

    it 'comes from an endpoint a class adds its options to' do
      configure
      klass = Class.new do
        include ApiRecipes
        api :svc, endpoints: { things: { timeout: 11 } }
      end
      expect_timeout(11)
      klass.svc.things.part.leaf.run
    end
  end

  describe 'on_bad_code' do
    it 'comes from the nearest endpoint above that has one' do
      svc = configure({ on_bad_code: 'ignore' })
      respond('/things/part/leaf', status: 500)
      expect(svc.things.part.leaf.run.code).to eq(500)
    end

    it 'is the one of the endpoint itself when it has one' do
      svc = configure({ on_bad_code: 'ignore' }, {}, { on_bad_code: 'raise' })
      respond('/things/part/leaf', status: 500)
      expect { svc.things.part.leaf.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
    end

    it 'does not reach an endpoint that is not below' do
      svc = configure({ on_bad_code: 'ignore' })
      respond('/other', status: 500)
      expect { svc.other.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
    end
  end

  describe 'mime_type' do
    it 'comes from the nearest endpoint above that has one' do
      svc = configure({ mime_type: 'application/json' }, {}, {}, mime_type: 'text/plain')
      respond('/things/part/leaf', body: '{"a":1}', headers: { 'Content-Type' => 'text/plain' })
      expect(svc.things.part.leaf.run.data).to eq('a' => 1)
    end

    it 'is the one of the endpoint itself when it has one' do
      svc = configure({ mime_type: 'text/plain' }, {}, { mime_type: 'application/json' })
      respond('/things/part/leaf', body: '{"a":1}', headers: { 'Content-Type' => 'text/plain' })
      expect(svc.things.part.leaf.run.data).to eq('a' => 1)
    end
  end

  describe 'verify_with' do
    it 'comes from the nearest endpoint above that has one' do
      configure({ verify_with: :refuse })
      klass = Class.new do
        include ApiRecipes
        api :svc

        def refuse(_response) = false
      end
      respond('/things/part/leaf')
      expect { klass.new.svc.things.part.leaf.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected, /Verified with refuse/)
    end
  end

  describe 'what describes one endpoint' do
    it 'keeps ok_code on the endpoint that has it: the one below accepts every 2xx' do
      svc = configure({ ok_code: 201 })
      respond('/things/part/leaf', status: 200)
      respond('/things', status: 200)
      expect(svc.things.part.leaf.run.code).to eq(200)
      expect { svc.things.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
    end

    it 'keeps verb and route on the endpoint that has them' do
      svc = configure({ verb: :post, route: false })
      expect(svc.things.part.leaf.definition.to_h.values_at(:verb, :route)).to eq([:get, true])
    end
  end

  it 'reaches the endpoints that resource adds' do
    configure_test_apis(svc: { host: 'api.example.test',
                               endpoints: { orders: { resource: true, timeout: 12, on_bad_code: 'ignore' } } })
    stub_request(:delete, "#{base_url}/orders/7").to_return(status: 500)
    expect_timeout(12)
    expect(ApiRecipes.svc.orders.delete(7).run.code).to eq(500)
  end

  it 'shows in definition the values an endpoint takes from above' do
    svc = configure({ timeout: 9, on_bad_code: 'ignore', mime_type: 'text/csv', verify_with: :check })
    leaf = svc.things.part.leaf.definition
    expect(leaf.to_h.values_at(:timeout, :on_bad_code, :mime_type, :verify_with)).to eq([9, 'ignore', 'text/csv', :check])
    expect([leaf.timeout, leaf.on_bad_code, leaf.mime_type, leaf.verify_with]).to eq([9, 'ignore', 'text/csv', :check])
  end
end
