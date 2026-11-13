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
end
