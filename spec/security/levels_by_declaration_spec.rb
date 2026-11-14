require 'spec_helper'
require 'yaml'

# A level written on a class, a module or an object belongs to the declaration
# it was written through. A request served by another declaration of the same
# api never reads it, whatever include, extend or prepend did before or after
# the first request. Each example records the host of every request and its
# Authorization header.
describe 'Levels written through one declaration of an api' do
  let(:sent) { [] }
  let(:shop) { { host: '{shop}.example.test', variables: { shop: {} }, endpoints: { orders: nil } } }

  before do
    configure_test_apis(svc: { host: 'good.example.test', endpoints: { users: nil } }, shop: shop)
    log = sent
    stub_request(:any, /\.test/).to_return do |request|
      log << [request.uri.host, request.headers['Authorization']]
      { status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' } }
    end
  end

  def declaring_module(name = :svc, **options)
    Module.new do
      include ApiRecipes
      api name, options
    end
  end

  # A module that uses the global tree of svc, and one that sends it to evil.test.
  def good_module = declaring_module

  def evil_module = declaring_module(host: 'evil.test')

  # Both directions: [module that writes the level, module that serves the
  # request, host the request must reach].
  def directions
    [[good_module, evil_module, 'evil.test'], [evil_module, good_module, 'good.example.test']]
  end

  # What the block sent, as [[host, Authorization]], or [error class, what was sent].
  def outcome
    sent.clear
    yield
    sent.dup
  rescue ApiRecipes::Error => e
    [e.class, sent.dup]
  end

  describe 'when a module arrives after the first request' do
    it 'does not send the credential of a module included into the module in use' do
      good = good_module
      good.svc.authorization = 'Bearer GOOD-MODULE'
      evil = evil_module
      client = Class.new { include evil }
      expect(outcome { client.new.svc.users.run }).to eq([['evil.test', nil]])
      evil.include(good)
      expect(outcome { client.new.svc.users.run }).to eq([['evil.test', nil]])
      expect(client.new.svc.authorization).to be_nil
    end

    it 'does not send the credential of a module included into the superclass' do
      good = good_module
      good.svc.authorization = 'Bearer GOOD-MODULE'
      evil = evil_module
      base = Class.new
      client = Class.new(base) { include evil }
      expect(outcome { client.new.svc.users.run }).to eq([['evil.test', nil]])
      base.include(good)
      expect(outcome { client.new.svc.users.run }).to eq([['evil.test', nil]])
    end

    it 'does not send it from an endpoint built before the include and run after' do
      good = good_module
      good.svc.authorization = 'Bearer GOOD-MODULE'
      evil = evil_module
      client = Class.new { include evil }
      held = client.new.svc.users
      evil.include(good)
      expect(outcome { held.run }).to eq([['evil.test', nil]])
    end

    it 'does not send it from an endpoint built before the include, in the other direction' do
      evil = evil_module
      evil.svc.authorization = 'Bearer EVIL-MODULE'
      good = good_module
      client = Class.new { include good }
      held = client.new.svc.users
      good.include(evil)
      expect(outcome { held.run }).to eq([['good.example.test', nil]])
      expect(outcome { client.new.svc.users.run }).to eq([['good.example.test', nil]])
    end

    it 'does not send the credential of a module included into a declaring class' do
      evil = evil_module
      evil.svc.authorization = 'Bearer EVIL-MODULE'
      klass = Class.new do
        include ApiRecipes
        api :svc
      end
      expect(outcome { klass.new.svc.users.run }).to eq([['good.example.test', nil]])
      klass.include(evil)
      expect(outcome { klass.new.svc.users.run }).to eq([['good.example.test', nil]])
      expect(outcome { klass.svc.users.run }).to eq([['good.example.test', nil]])
      klass.svc.authorization = 'Bearer CLASS'
      expect(outcome { klass.new.svc.users.run }).to eq([['good.example.test', 'Bearer CLASS']])
    end

    it 'does not send the credential of a module included into the superclass of a subclass already used' do
      evil = evil_module
      evil.svc.authorization = 'Bearer EVIL-MODULE'
      parent = Class.new do
        include ApiRecipes
        api :svc
      end
      child = Class.new(parent)
      expect(outcome { child.new.svc.users.run }).to eq([['good.example.test', nil]])
      parent.include(evil)
      expect(outcome { child.new.svc.users.run }).to eq([['good.example.test', nil]])
      expect(child.new.svc.authorization).to be_nil
    end

    it 'keeps the class credential for the class and refuses the prepended declaration' do
      klass = Class.new do
        include ApiRecipes
        api :svc
      end
      klass.svc.authorization = 'Bearer CLASS'
      expect(outcome { klass.svc.users.run }).to eq([['good.example.test', 'Bearer CLASS']])
      evil = evil_module
      evil.svc.authorization = 'Bearer EVIL-MODULE'
      klass.prepend(evil)
      expect(outcome { klass.svc.users.run }).to eq([['good.example.test', 'Bearer CLASS']])
      expect(outcome { klass.new.svc.users.run }).to eq([ApiRecipes::ApiNameClashError, []])
    end
  end

  describe 'when a class or a module holds a level written through a module it was extended with' do
    it 'does not read the level of a module included next to the declaring module' do
      directions.each do |writer, user, host|
        holder = Module.new
        holder.extend(writer)
        holder.svc.authorization = 'Bearer HOLDER'
        client = Class.new do
          include holder
          include user
        end
        expect(outcome { client.new.svc.users.run }).to eq([[host, nil]])
        expect(client.new.svc.authorization).to be_nil
      end
    end

    it 'does not read the level of a superclass for the module a subclass includes' do
      directions.each do |writer, user, host|
        parent = Class.new
        parent.extend(writer)
        parent.svc.authorization = 'Bearer PARENT'
        child = Class.new(parent) { include user }
        expect(outcome { child.new.svc.users.run }).to eq([[host, nil]])
      end
    end

    it 'does not read the level of a superclass for the declaration of a subclass' do
      [[evil_module, {}, 'good.example.test'], [good_module, { host: 'evil.test' }, 'evil.test']]
        .each do |writer, options, host|
          parent = Class.new
          parent.extend(writer)
          parent.svc.authorization = 'Bearer PARENT'
          child = Class.new(parent) do
            include ApiRecipes
            api :svc, options.merge(as: :own_svc)
          end
          expect(outcome { child.new.own_svc.users.run }).to eq([[host, nil]])
        end
    end

    it 'reads no module of the singleton class of an object' do
      directions.each do |writer, user, host|
        helper = Module.new do
          def helper = 1
        end
        helper.extend(writer)
        helper.svc.authorization = 'Bearer HELPER'
        object = Class.new { include user }.new
        object.extend(helper)
        expect(outcome { object.svc.users.run }).to eq([[host, nil]])
      end
    end

    it 'does not read variables written through another declaration' do
      holder = Module.new
      holder.extend(declaring_module(:shop))
      holder.shop.variables = { shop: 'evil' }
      user = declaring_module(:shop)
      client = Class.new do
        include holder
        include user
      end
      expect { client.new.shop.orders.url }.to raise_error(ApiRecipes::MissingVariable, /shop/)
      expect(client.new.shop.variables).to eq({})
    end
  end

  describe 'what keeps working' do
    it 'lets a class extended with a declaring module use the level of that module and pass its own to subclasses' do
      good = good_module
      good.svc.authorization = 'Bearer MODULE'
      parent = Class.new
      parent.extend(good)
      expect(outcome { parent.svc.users.run }).to eq([['good.example.test', 'Bearer MODULE']])
      parent.svc.authorization = 'Bearer PARENT'
      child = Class.new(parent)
      expect(outcome { child.svc.users.run }).to eq([['good.example.test', 'Bearer PARENT']])
      expect(child.svc.authorization).to eq('Bearer PARENT')
    end

    it 'sends no credential from a restored object, and inherits none' do
      stub_const('RestoredClient', Class.new { include ApiRecipes })
      RestoredClient.api :svc
      RestoredClient.svc.authorization = 'Bearer CLASS'
      object = RestoredClient.new
      object.svc.authorization = 'Bearer INSTANCE'
      [Marshal.load(Marshal.dump(object)), YAML.unsafe_load(YAML.dump(object))].each do |restored|
        expect(outcome { restored.svc.users.run }).to eq([['good.example.test', nil]])
        expect(restored.svc.authorization).to be_nil
      end
      expect(outcome { RestoredClient.new.svc.users.run }).to eq([['good.example.test', 'Bearer CLASS']])
    end

    it 'keeps every other api of a restored object without credential after a write on one of them' do
      configure_test_apis(svc: { host: 'good.example.test', endpoints: { users: nil } },
                          oth: { host: 'oth.example.test', endpoints: { users: nil } })
      stub_const('RestoredTwo', Class.new { include ApiRecipes })
      RestoredTwo.api :svc
      RestoredTwo.api :oth
      RestoredTwo.svc.authorization = 'Bearer CLASS-SVC'
      RestoredTwo.oth.authorization = 'Bearer CLASS-OTH'
      object = RestoredTwo.new
      object.svc.authorization = 'Bearer INSTANCE-SVC'
      [Marshal.load(Marshal.dump(object)), YAML.unsafe_load(YAML.dump(object))].each do |restored|
        restored.svc.authorization = 'Bearer NEW-SVC'
        expect(outcome { restored.svc.users.run }).to eq([['good.example.test', 'Bearer NEW-SVC']])
        expect(outcome { restored.oth.users.run }).to eq([['oth.example.test', nil]])
        restored.svc.variables = {}
        expect(outcome { restored.svc.users.run }).to eq([['good.example.test', 'Bearer NEW-SVC']])
        expect(outcome { restored.oth.users.run }).to eq([['oth.example.test', nil]])
        restored.oth.variables = {}
        expect(outcome { restored.oth.users.run }).to eq([['oth.example.test', nil]])
        expect(restored.oth.authorization).to be_nil
      end
    end

    it 'creates no singleton class for an object that reaches a module declaration through a copied method' do
      good = good_module
      good.svc.authorization = 'Bearer MODULE'
      klass = Class.new
      klass.define_method(:svc, good.instance_method(:svc))
      objects = Array.new(3) { klass.new }
      objects.each { |object| object.svc.users.run }
      attached = ObjectSpace.each_object(Class).select(&:singleton_class?).map(&:attached_object)
      expect(attached.select { |owner| objects.any? { |object| object.equal?(owner) } }).to eq([])
      expect(sent).to eq([['good.example.test', 'Bearer MODULE']] * 3)
    end
  end
end
