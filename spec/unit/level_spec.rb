require 'spec_helper'
require 'json'
require 'yaml'
require 'pp'
require 'stringio'

describe ApiRecipes::Internals::LevelSet do
  let(:klass) { Class.new }
  let(:token) { ApiRecipes::Internals::Credential.authorization('Bearer SECRET') }

  def set(owner, credential) = described_class.write(owner, :svc) { |level| level.with(credential: credential) }

  it 'keeps a value per owner and per api' do
    a = klass.new
    b = klass.new
    set(a, token)
    expect(described_class.read(a, :svc).credential).to equal(token)
    expect(described_class.read(a, :other)).to be_nil
    expect(described_class.read(b, :svc)).to be_nil
  end

  it 'does not lose the write another thread makes between the read and the store of a write' do
    owner = klass.new
    entered = Queue.new
    release = Queue.new
    first = Thread.new do
      described_class.write(owner, :a) do |level|
        entered << true
        release.pop(timeout: 5)
        level.with(variables: { n: 1 })
      end
    end
    expect(entered.pop(timeout: 5)).to be(true)
    second = Thread.new { described_class.write(owner, :b) { |level| level.with(variables: { n: 2 }) } }
    second.join(0.2)
    release << true
    expect([first.join(5), second.join(5)]).to eq([first, second])
    expect(described_class.read(owner, :a).variables).to eq(n: 1)
    expect(described_class.read(owner, :b).variables).to eq(n: 2)
  end

  it 'is replaced, not mutated: a copy cannot change the original' do
    a = klass.new
    set(a, token)
    copy = a.dup
    set(copy, ApiRecipes::Internals::Credential::NONE)
    expect(described_class.read(a, :svc).credential).to equal(token)
  end

  it 'shows no secret in inspect, even through its owner' do
    a = klass.new
    set(a, token)
    expect(a.inspect).not_to include('SECRET')
  end

  it 'writes no secret when serialized, and a restored owner has no credential and inherits none' do
    stub_const('Client', Class.new)
    a = Client.new
    set(a, token)
    dumped = Marshal.dump(a)
    expect(dumped).not_to include('SECRET')
    expect(a.instance_variable_get(:@__api_recipes).to_json).not_to include('SECRET')
    expect(YAML.dump(a)).not_to include('SECRET')
    restored = Marshal.load(dumped)
    expect(described_class.read(restored, :svc).credential).to equal(ApiRecipes::Internals::Credential::NONE)
    expect(described_class.read(restored, :anything).credential).to equal(ApiRecipes::Internals::Credential::NONE)
  end

  it 'explains what to do with a frozen owner' do
    expect { set(klass.new.freeze, token) }.to raise_error(ApiRecipes::Error, /with\(/)
  end

  it 'forgets everything on reset' do
    a = klass.new
    set(a, token)
    described_class.reset!
    expect(described_class.read(a, :svc)).to be_nil
  end
end

describe ApiRecipes::Internals::Level do
  let(:level) do
    described_class.new(credential: ApiRecipes::Internals::Credential.authorization('Bearer SECRET'),
                        variables: { k: 'VARSECRET' }.freeze)
  end

  it 'prints no secret with pp, also for a credential and a level set' do
    owner = Object.new
    ApiRecipes::Internals::LevelSet.write(owner, :svc) { level }
    [level, level.credential, owner.instance_variable_get(:@__api_recipes)].each do |object|
      io = StringIO.new
      PP.pp(object, io)
      expect(io.string).not_to include('SECRET')
    end
  end

  it 'writes no secret when serialized' do
    [Marshal.dump(level), YAML.dump(level), level.to_json, level.as_json.to_s].each do |text|
      expect(text).not_to include('SECRET')
    end
    restored = Marshal.load(Marshal.dump(level))
    expect(restored.credential.none?).to eq(true)
    expect(restored.variables).to be_nil
  end
end

describe 'restored objects' do
  let(:level) do
    ApiRecipes::Internals::Level.new(credential: ApiRecipes::Internals::Credential.authorization('Bearer SECRET'),
                          variables: { k: 'VARSECRET' }.freeze)
  end
  let(:restorers) do
    [->(x) { Marshal.load(Marshal.dump(x)) }, ->(x) { YAML.unsafe_load(YAML.dump(x)) }]
  end

  it 'restores a level, a credential and a level set as "no credential, inherit nothing"' do
    owner = Object.new
    ApiRecipes::Internals::LevelSet.write(owner, :svc) { level }
    set = owner.instance_variable_get(:@__api_recipes)
    restorers.each do |restore|
      restored = restore.call(level)
      expect(restored.credential.none?).to eq(true)
      expect(restored.variables).to be_nil
      expect(restore.call(level.credential).none?).to eq(true)
      expect(restore.call(level.credential).value).to be_nil
      again = restore.call(set)
      expect(again.fetch(:anything).credential.none?).to eq(true)
      expect(again.fetch(:anything).variables).to be_nil
    end
  end
end

describe ApiRecipes::Internals::Levels do
  def values(chain) = chain.map { |kind, level| [kind, level.variables[:n]] }

  def numbered(value) = ->(level) { level.with(variables: { n: value }.freeze) }

  # A set put on a class or a module by force: nothing of the library writes one.
  def force(owner, key, value)
    sets = ApiRecipes::Internals::LevelSet
    level = ApiRecipes::Internals::Level.new(credential: nil, variables: { n: value }.freeze)
    owner.instance_variable_set(sets::IVAR, sets.new({ key => level }.compare_by_identity, sets.generation))
  end

  it 'goes from the object to the class that declared the api, then to the application' do
    parent = Class.new
    child = Class.new(parent)
    object = child.new
    declaration = ApiRecipes::Internals::Declaration.new(parent, :svc, {}, nil)
    write_level(object, declaration, &numbered(0))
    force(child, declaration, 1)
    write_level(parent, declaration, &numbered(2))
    write_level(ApiRecipes, :svc, &numbered(3))
    chain = described_class.chain(object, :svc, declaration)
    expect(chain.map(&:first)).to eq(%i[instance class global])
    # The set forced on child, which did not declare the api, is not read.
    expect(values(chain)).to eq([[:instance, 0], [:class, 2], [:global, 3]])
    expect(values(described_class.chain(child, :svc, declaration))).to eq([[:class, 2], [:global, 3]])
    expect(values(described_class.chain(parent, :svc, declaration))).to eq([[:class, 2], [:global, 3]])
    expect(described_class.chain(ApiRecipes, :svc, nil).map(&:first)).to eq(%i[global])
    expect(chain).to be_frozen
    expect(chain.registry).to equal(ApiRecipes::Internals::Registry.current)
  end

  it 'refuses to write a set on a class, a module or the ApiRecipes module' do
    declaration = ApiRecipes::Internals::Declaration.new(Class.new, :svc, {}, nil)
    [Class.new, Module.new, ApiRecipes, Class.new.singleton_class, declaration.declared_in].each do |owner|
      expect { ApiRecipes::Internals::LevelSet.write(owner, declaration, &numbered(1)) }
        .to raise_error(ApiRecipes::Error, 'a level is written on an object, not on a class or a module')
      expect(owner.instance_variable_get(ApiRecipes::Internals::LevelSet::IVAR)).to be_nil
    end
  end

  it 'returns only the levels of the declaration: the one written through it on the object and the one of the module that declared it' do
    declarer = Module.new
    declaration = ApiRecipes::Internals::Declaration.new(declarer, :svc, {}, nil)
    other_declarer = Module.new
    other = ApiRecipes::Internals::Declaration.new(other_declarer, :svc, {}, nil)
    klass = Class.new
    object = klass.new
    write_level(object, other, &numbered('other'))
    write_level(other_declarer, other, &numbered('other'))
    [klass, declarer].each { |owner| force(owner, other, 'other') }
    write_level(ApiRecipes, :svc, &numbered('global'))
    expect(values(described_class.chain(object, :svc, declaration))).to eq([[:global, 'global']])
    write_level(declarer, declaration, &numbered('module'))
    force(klass, declaration, 'class')
    expect(values(described_class.chain(object, :svc, declaration))).to eq([[:class, 'module'], [:global, 'global']])
    klass.include(declarer)
    write_level(object, declaration, &numbered('object'))
    expect(values(described_class.chain(object, :svc, declaration)))
      .to eq([[:instance, 'object'], [:class, 'module'], [:global, 'global']])
    expect(values(described_class.chain(object, :svc, other)))
      .to eq([[:instance, 'other'], [:class, 'other'], [:global, 'global']])
    expect(values(described_class.chain(klass, :svc, declaration))).to eq([[:class, 'module'], [:global, 'global']])
    expect(values(described_class.chain(object, :svc, nil))).to eq([[:global, 'global']])
  end

  it 'gives the level of the owner alone to the readers' do
    declarer = Class.new
    declaration = ApiRecipes::Internals::Declaration.new(declarer, :svc, {}, nil)
    object = declarer.new
    write_level(ApiRecipes, :svc, &numbered('global'))
    expect(described_class.own(object, :svc, declaration)).to be_nil
    expect(described_class.own(declarer, :svc, declaration)).to be_nil
    write_level(declarer, declaration, &numbered('class'))
    write_level(object, declaration, &numbered('object'))
    expect(described_class.own(object, :svc, declaration).variables).to eq(n: 'object')
    expect(described_class.own(declarer, :svc, declaration).variables).to eq(n: 'class')
    expect(described_class.own(Class.new(declarer), :svc, declaration).variables).to eq(n: 'class')
    expect(described_class.own(ApiRecipes, :svc, nil).variables).to eq(n: 'global')
  end
end
