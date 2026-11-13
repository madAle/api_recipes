require 'spec_helper'
require 'json'
require 'yaml'
require 'pp'
require 'stringio'

describe ApiRecipes::Core::LevelSet do
  let(:klass) { Class.new }
  let(:token) { ApiRecipes::Core::Credential.authorization('Bearer SECRET') }

  def set(owner, credential) = described_class.write(owner, :svc) { |level| level.with(credential: credential) }

  it 'keeps a value per owner and per api' do
    a = klass.new
    b = klass.new
    set(a, token)
    expect(described_class.read(a, :svc).credential).to equal(token)
    expect(described_class.read(a, :other)).to be_nil
    expect(described_class.read(b, :svc)).to be_nil
  end

  it 'is replaced, not mutated: a copy cannot change the original' do
    a = klass.new
    set(a, token)
    copy = a.dup
    set(copy, ApiRecipes::Core::Credential::NONE)
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
    expect(described_class.read(restored, :svc).credential).to equal(ApiRecipes::Core::Credential::NONE)
    expect(described_class.read(restored, :anything).credential).to equal(ApiRecipes::Core::Credential::NONE)
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

describe ApiRecipes::Core::Level do
  let(:level) do
    described_class.new(credential: ApiRecipes::Core::Credential.authorization('Bearer SECRET'),
                        variables: { k: 'VARSECRET' }.freeze)
  end

  it 'prints no secret with pp, also for a credential and a level set' do
    owner = Object.new
    ApiRecipes::Core::LevelSet.write(owner, :svc) { level }
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
    ApiRecipes::Core::Level.new(credential: ApiRecipes::Core::Credential.authorization('Bearer SECRET'),
                          variables: { k: 'VARSECRET' }.freeze)
  end
  let(:restorers) do
    [->(x) { Marshal.load(Marshal.dump(x)) }, ->(x) { YAML.unsafe_load(YAML.dump(x)) }]
  end

  it 'restores a level, a credential and a level set as "no credential, inherit nothing"' do
    owner = Object.new
    ApiRecipes::Core::LevelSet.write(owner, :svc) { level }
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

describe ApiRecipes::Core::Levels do
  def write(owner, key, value)
    ApiRecipes::Core::LevelSet.write(owner, key) { |level| level.with(variables: { n: value }.freeze) }
  end

  def values(chain) = chain.map { |kind, level| [kind, level.variables[:n]] }

  it 'walks from the instance to the global api' do
    parent = Class.new
    child = Class.new(parent)
    object = child.new
    declaration = ApiRecipes::Core::Declaration.new(parent, :svc, {}, nil)
    [object, child, parent, ApiRecipes].each_with_index do |owner, index|
      ApiRecipes::Core::LevelSet.write(owner, owner.equal?(ApiRecipes) ? :svc : declaration) do |level|
        level.with(variables: { n: index }.freeze)
      end
    end
    chain = described_class.chain(object, :svc, declaration)
    expect(chain.map(&:first)).to eq(%i[instance class class global])
    expect(chain.map { |_, level| level.variables[:n] }).to eq([0, 1, 2, 3])
    expect(described_class.chain(child, :svc, declaration).map(&:first)).to eq(%i[class class global])
    expect(described_class.chain(ApiRecipes, :svc, nil).map(&:first)).to eq(%i[global])
  end

  it 'returns only the levels written through the declaration, then the one of the module that declared it' do
    declarer = Module.new
    declaration = ApiRecipes::Core::Declaration.new(declarer, :svc, {}, nil)
    other = ApiRecipes::Core::Declaration.new(Module.new, :svc, {}, nil)
    klass = Class.new
    object = klass.new
    [object, klass, declarer].each { |owner| write(owner, other, 'other') }
    write(klass, :svc, 'by name')
    write(ApiRecipes, :svc, 'global')
    expect(values(described_class.chain(object, :svc, declaration))).to eq([[:global, 'global']])
    write(declarer, declaration, 'module')
    write(klass, declaration, 'class')
    expect(values(described_class.chain(object, :svc, declaration)))
      .to eq([[:class, 'class'], [:class, 'module'], [:global, 'global']])
    klass.include(declarer)
    expect(values(described_class.chain(object, :svc, declaration)))
      .to eq([[:class, 'class'], [:class, 'module'], [:global, 'global']])
    expect(values(described_class.chain(object, :svc, nil))).to eq([[:global, 'global']])
  end
end
