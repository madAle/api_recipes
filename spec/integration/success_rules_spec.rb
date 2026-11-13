require 'spec_helper'

describe 'What counts as a successful response' do
  let(:url) { "#{base_url}/things" }

  def configure(endpoint = {}, api = {})
    configure_test_apis(svc: { host: 'api.example.test' }.merge(api).merge(endpoints: { things: endpoint }))
    ApiRecipes.svc
  end

  def respond_with(status, body = '')
    stub_request(:get, url).to_return(status: status, body: body)
  end

  describe 'by default' do
    [200, 201, 204, 299].each do |status|
      it "accepts #{status}" do
        respond_with(status)
        expect(configure.things.run.code).to eq(status)
      end
    end

    [301, 400, 404, 500].each do |status|
      it "raises on #{status}" do
        respond_with(status)
        expect { configure.things.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
      end
    end

    it 'describes the failure in the error' do
      respond_with(404, 'missing')
      expect { configure.things.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected) do |error|
        expect(error.message).to eq("response code for request on route '/things' has returned '404', " \
                                    "but '200 <= CODE < 300' was expected")
        expect(error.path).to eq('/things')
        expect(error.expected_code).to eq('200 <= CODE < 300')
        expect(error.response.code).to eq(404)
        expect(error.response.body.to_s).to eq('missing')
      end
    end
  end

  describe 'ok_code' do
    it 'accepts only that status' do
      respond_with(201)
      expect(configure(ok_code: 201).things.run.code).to eq(201)
    end

    it 'raises on another 2xx status and reports the expected one' do
      respond_with(200)
      expect { configure(ok_code: 201).things.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected) do |error|
        expect(error.expected_code).to eq(201)
      end
    end

    it 'can expect a status outside the 2xx range' do
      respond_with(404)
      expect(configure(ok_code: 404).things.run.code).to eq(404)
    end
  end

  describe 'on_bad_code' do
    ['ignore', :ignore].each do |value|
      it "returns the response instead of raising with #{value.inspect}" do
        respond_with(500)
        response = configure(on_bad_code: value).things.run
        expect(response.code).to eq(500)
        expect(response.status.success?).to eq(false)
      end
    end

    ['raise', :raise].each do |value|
      it "raises with #{value.inspect}" do
        respond_with(500)
        expect { configure(on_bad_code: value).things.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
      end
    end

    it 'takes the value of the api' do
      respond_with(500)
      expect(configure({}, on_bad_code: 'ignore').things.run.code).to eq(500)
    end

    it 'takes the value of the endpoint over that of the api' do
      respond_with(500)
      expect { configure({ on_bad_code: 'raise' }, on_bad_code: 'ignore').things.run }
        .to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
    end

    it 'applies to ok_code too' do
      respond_with(200)
      expect(configure(ok_code: 201, on_bad_code: 'ignore').things.run.code).to eq(200)
    end
  end

  describe 'verify_with' do
    let(:klass) do
      Class.new do
        include ApiRecipes
        api :svc

        def self.accept(_response)
          true
        end

        def self.refuse(_response)
          false
        end

        def check
          svc.things.run
        end

        private

        def body_is_ok(response)
          response.body.to_s == 'ok'
        end
      end
    end

    it 'accepts any status when the method returns true' do
      respond_with(500)
      configure(verify_with: :accept)
      expect(klass.svc.things.run.code).to eq(500)
    end

    it 'raises on any status when the method returns false' do
      respond_with(200)
      configure(verify_with: :refuse)
      expect { klass.svc.things.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected, /Verified with/)
    end

    it 'accepts the method name as a String' do
      respond_with(500)
      configure(verify_with: 'accept')
      expect(klass.svc.things.run.code).to eq(500)
    end

    it 'calls a private method of the instance that makes the request' do
      configure(verify_with: :body_is_ok)
      respond_with(200, 'ok')
      expect(klass.new.check.code).to eq(200)

      respond_with(200, 'broken')
      expect { klass.new.check }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
    end

    it 'takes the value of the api' do
      respond_with(500)
      configure({}, verify_with: :accept)
      expect(klass.svc.things.run.code).to eq(500)
    end

    it 'is passed on to nested endpoints' do
      stub_request(:get, "#{base_url}/things/7").to_return(status: 500)
      configure(verify_with: :accept, endpoints: { show: { path: '/:id' } })
      expect(klass.svc.things.show(7).run.code).to eq(500)
    end

    it 'does not raise when on_bad_code is ignore' do
      respond_with(200)
      configure(verify_with: :refuse, on_bad_code: 'ignore')
      expect(klass.svc.things.run.code).to eq(200)
    end

    it 'falls back to the status check when the caller has no such method' do
      configure(verify_with: :accept)
      respond_with(200)
      expect(ApiRecipes.svc.things.run.code).to eq(200)

      respond_with(500)
      expect { ApiRecipes.svc.things.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
    end
  end
end
