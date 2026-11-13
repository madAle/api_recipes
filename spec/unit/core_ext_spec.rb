require 'spec_helper'

# A Hash subclass whose constructor needs an argument, like Dotenv::Environment
class HashRequiringAnArgument < Hash
  def initialize(name)
    super()
    @name = name
  end
end

# Ruby has had Hash#transform_keys and #transform_keys! since 2.5: api_recipes adds
# its own helpers to Hash, but must leave the core ones alone.
describe 'Hash core extensions' do
  describe '#transform_keys' do
    it 'should work on a Hash subclass whose constructor needs arguments' do
      hash = HashRequiringAnArgument.new('env')
      hash[:a] = 1

      expect(hash.transform_keys(&:to_s)).to eq('a' => 1)
    end

    it 'should accept a hash mapping old keys to new ones', if: RUBY_VERSION >= '3.0' do
      expect({ a: 1, b: 2 }.transform_keys(a: :x)).to eq(x: 1, b: 2)
    end
  end

  describe '#transform_keys!' do
    it 'should accept a hash mapping old keys to new ones', if: RUBY_VERSION >= '3.0' do
      hash = { a: 1, b: 2 }
      hash.transform_keys!(a: :x)

      expect(hash).to eq(x: 1, b: 2)
    end
  end

  describe '#symbolize_keys and #stringify_keys' do
    it 'should keep working on top of the core transform_keys' do
      expect({ 'a' => 1 }.symbolize_keys).to eq(a: 1)
      expect({ a: 1 }.stringify_keys).to eq('a' => 1)
    end
  end

  describe 'key conversion' do
    it 'converts keys in place with the bang methods' do
      hash = { 'a' => 1 }
      expect(hash.symbolize_keys!).to equal(hash)
      expect(hash).to eq(a: 1)

      expect(hash.stringify_keys!).to equal(hash)
      expect(hash).to eq('a' => 1)
    end

    it 'leaves keys that cannot become symbols as they are' do
      expect({ 1 => 'a', 'b' => 2 }.symbolize_keys).to eq(1 => 'a', b: 2)
    end

    it 'converts keys of nested hashes and of hashes inside arrays' do
      nested = { 'a' => { 'b' => [{ 'c' => 1 }, 2] } }
      expect(nested.deep_symbolize_keys).to eq(a: { b: [{ c: 1 }, 2] })
      expect(nested.deep_symbolize_keys.deep_stringify_keys).to eq(nested)
      expect(nested).to eq('a' => { 'b' => [{ 'c' => 1 }, 2] })
    end

    it 'converts nested keys in place with the bang methods' do
      hash = { 'a' => { 'b' => [{ 'c' => 1 }] } }
      hash.deep_symbolize_keys!
      expect(hash).to eq(a: { b: [{ c: 1 }] })
      hash.deep_stringify_keys!
      expect(hash).to eq('a' => { 'b' => [{ 'c' => 1 }] })
    end

    it 'converts nested keys with a block' do
      expect({ a: { b: 1 } }.deep_transform_keys { |key| key.to_s.upcase }).to eq('A' => { 'B' => 1 })
    end
  end

  describe '#deep_merge' do
    it 'merges nested hashes and lets the other hash win' do
      expect({ a: 1, b: { c: 1, d: 2 } }.deep_merge(a: 2, b: { c: 3 })).to eq(a: 2, b: { c: 3, d: 2 })
    end

    it 'does not change the receiver' do
      hash = { b: { c: 1 } }
      hash.deep_merge(b: { c: 2 })
      expect(hash).to eq(b: { c: 1 })
    end

    it 'resolves conflicts with a block' do
      merged = { a: 1, b: { c: 1 } }.deep_merge(a: 2, b: { c: 3 }) { |_key, old, new| old + new }
      expect(merged).to eq(a: 3, b: { c: 4 })
    end

    it 'changes the receiver with the bang method' do
      hash = { a: 1 }
      hash.deep_merge!(b: 2)
      expect(hash).to eq(a: 1, b: 2)
    end
  end

  describe '#assert_valid_keys' do
    it 'accepts a hash whose keys are all allowed' do
      expect { { a: 1 }.assert_valid_keys(:a, :b) }.not_to raise_error
    end

    it 'raises for a key that is not allowed' do
      expect { { c: 1 }.assert_valid_keys(:a, :b) }.to raise_error(ArgumentError, /Unknown key: :c/)
    end
  end
end

describe 'Array core extensions' do
  describe '#extract_options!' do
    it 'removes and returns a trailing hash' do
      args = [1, 2, { a: :b }]
      expect(args.extract_options!).to eq(a: :b)
      expect(args).to eq([1, 2])
    end

    it 'returns an empty hash when the last element is not a hash' do
      args = [1, 2]
      expect(args.extract_options!).to eq({})
      expect(args).to eq([1, 2])
    end
  end
end
