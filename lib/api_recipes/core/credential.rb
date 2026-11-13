module ApiRecipes
  module Core
    # A secret sent with requests. It never shows its value: not in inspect, not
    # in to_s, not in error messages.
    class Credential
      KINDS = %i[authorization basic_auth none].freeze
      CONTROL_CHARACTERS = /[[:cntrl:]]/

      class << self
        def authorization(value)
          check_text(value, 'the authorization value')
          new(:authorization, value.dup.freeze)
        end

        def basic_auth(value)
          unless value.is_a?(Hash) && value.key?(:user) && value.key?(:pass)
            raise InvalidCredential, 'basic_auth must be a Hash with :user and :pass'
          end

          check_text(value[:user], 'the basic_auth user')
          check_text(value[:pass], 'the basic_auth pass')
          new(:basic_auth, { user: value[:user].dup.freeze, pass: value[:pass].dup.freeze }.freeze)
        end

        def from(kind, value)
          return NONE if value.nil?

          case kind
          when :authorization then authorization(value)
          when :basic_auth then basic_auth(value)
          else raise InvalidCredential, "unknown kind #{kind.inspect}"
          end
        end

        private

        def check_text(value, what)
          raise InvalidCredential, "#{what} must be a String" unless value.is_a?(String)
          raise InvalidCredential, "#{what} contains a control character" if value.match?(CONTROL_CHARACTERS)
        end
      end

      attr_reader :kind, :value

      def initialize(kind, value)
        @kind = kind
        @value = value
        freeze
      end

      def none? = @kind == :none

      def inspect = "#<ApiRecipes::Core::Credential #{@kind} [FILTERED]>"

      def to_s = inspect

      def pretty_print(queue) = queue.text(inspect)

      # Serialized forms never carry the value: a rebuilt credential is NONE-like.
      def marshal_dump = nil

      def marshal_load(_data)
        @kind = :none
        @value = nil
        freeze
      end

      def encode_with(coder)
        coder['kind'] = 'none'
      end

      def init_with(_coder)
        marshal_load(nil)
      end

      def as_json(*) = '[FILTERED]'

      def to_json(*) = '"[FILTERED]"'

      NONE = new(:none, nil)
    end
  end
end
