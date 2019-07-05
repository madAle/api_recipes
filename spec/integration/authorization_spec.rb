require 'spec_helper'
require 'support/constants'
require 'yaml'

describe 'ApiRecipes authorization' do
  let(:klass) { Object.const_get CLASS_NAME }

  context 'when the scope is a class' do

    before do
      klass.class_eval do
        include ApiRecipes
        endpoint ENDPOINT_NAME

        def set_authorization_from_instance_method
          send(ENDPOINT_NAME).authorization = AUTHORIZATION
        end

        def get_authorization_from_instance_method
          send(ENDPOINT_NAME).authorization
        end

        def self.set_authorization_from_class_method
          send(ENDPOINT_NAME).authorization = AUTHORIZATION
        end

        def self.get_authorization_from_class_method
          send(ENDPOINT_NAME).authorization
        end
      end
    end

    context "setting authorization from a #{CLASS_NAME}'s instance method" do
      let(:klass_instance) { klass.new }

      before do
        klass_instance.set_authorization_from_instance_method
      end

      it "should be accessible from any other instance method" do
        expect(klass_instance.get_authorization_from_instance_method).to eq AUTHORIZATION
      end

      it 'should be accessible from any other class method' do
        expect(klass.get_authorization_from_class_method).to eq AUTHORIZATION
      end
    end

    context "setting authorization from a #{CLASS_NAME}'s class method" do
      let(:klass_instance) { klass.new }

      before do
        klass.set_authorization_from_class_method
      end

      it "should be accessible from any other instance method" do
        expect(klass_instance.get_authorization_from_instance_method).to eq AUTHORIZATION
      end

      it 'should be accessible from any other class method' do
        expect(klass.get_authorization_from_class_method).to eq AUTHORIZATION
      end
    end
  end
end
