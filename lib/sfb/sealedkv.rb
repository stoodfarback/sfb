# frozen_string_literal: true

module Sfb
  module Sealedkv
    RPC_KEY = "sealedkv_v1"
    CONFIG_FILE = ".sealedkv"
    KEY_PREFIX = "sealedkv-key-v1:"
    NAME_PATTERN = /\A[a-z0-9_-]+\z/
    KEY_BYTES = 32
    NONCE_BYTES = 24
    MAC_BYTES = 16
    CLIENT_TIMEOUT_SECONDS = 1
    CLIENT_WAIT_FOR_SERVER_SECONDS = 1

    def self.get(secret_name)
      instance.get(secret_name)
    end

    def self.instance
      @instance ||= Client.new
    end

    def self.reset!
      @instance = nil
    end

    class Client
      extend Sfb::Memo

      # Raises on any failure (missing secret, broker down, timeout, decrypt
      # failure, etc). Errors are not rescued here; the consumer decides how
      # to handle them and which Urpc errors to distinguish.
      def get(secret_name)
        secret_name = Sfb::Sealedkv.validate_name!("secret name", secret_name)
        identity = self.identity

        blob = urpc.get_secret(project_name: identity.project_name, secret_name:)

        Crypto.decrypt_value(
          project_name: identity.project_name,
          secret_name:,
          key: identity.key,
          blob:
        )
      end

      memo def identity = ProjectIdentity.discover

      memo def urpc = Urpc::Client.new(
        RPC_KEY,
        timeout: CLIENT_TIMEOUT_SECONDS,
        wait_for_server: CLIENT_WAIT_FOR_SERVER_SECONDS
      )
    end

    def self.validate_name!(kind, value)
      if !value.is_a?(String) || !value.match?(NAME_PATTERN)
        raise(ArgumentError, "invalid #{kind}: #{value.inspect}; must match #{NAME_PATTERN.source}")
      end

      value
    end

    class ProjectIdentity
      attr_accessor(:path, :project_name, :key)

      def initialize(path:, project_name:, key:)
        self.path = File.expand_path(path.to_s)
        self.project_name = Sfb::Sealedkv.validate_name!("project name", project_name)
        self.key = String(key).b

        if self.key.bytesize != Sfb::Sealedkv::KEY_BYTES
          raise(ArgumentError, "project key must be #{Sfb::Sealedkv::KEY_BYTES} bytes")
        end
      end

      def self.discover(start_dir: Dir.pwd)
        path = find_path(start_dir:)
        if !path
          raise("no #{Sfb::Sealedkv::CONFIG_FILE} found at or above #{File.expand_path(start_dir)}")
        end

        load(path)
      end

      def self.find_path(start_dir: Dir.pwd)
        dir = File.expand_path(start_dir)
        if !File.directory?(dir)
          raise(ArgumentError, "not a directory: #{dir}")
        end

        loop do
          candidate = File.join(dir, Sfb::Sealedkv::CONFIG_FILE)
          return(candidate) if File.file?(candidate)

          parent = File.dirname(dir)
          return if parent == dir

          dir = parent
        end
      end

      def self.load(path)
        path = File.expand_path(path.to_s)
        data = begin
          JSON.parse(File.binread(path))
        rescue JSON::ParserError => e
          raise(ArgumentError, "invalid #{Sfb::Sealedkv::CONFIG_FILE} JSON at #{path}: #{e.message}")
        end

        if !data.is_a?(Hash)
          raise(ArgumentError, "#{Sfb::Sealedkv::CONFIG_FILE} must contain a JSON object")
        end

        if data.keys.sort != ["key", "project"]
          raise(ArgumentError, "#{Sfb::Sealedkv::CONFIG_FILE} must contain exactly project and key fields")
        end

        new(
          path:,
          project_name: data.fetch("project"),
          key: KeyEncoding.decode(data.fetch("key"))
        )
      end
    end

    module KeyEncoding
      def self.encode(raw_key)
        raw_key = String(raw_key).b
        if raw_key.bytesize != Sfb::Sealedkv::KEY_BYTES
          raise(ArgumentError, "sealedkv keys must be #{Sfb::Sealedkv::KEY_BYTES} bytes")
        end

        "#{Sfb::Sealedkv::KEY_PREFIX}#{Base64.strict_encode64(raw_key)}"
      end

      def self.decode(encoded_key)
        if !encoded_key.is_a?(String) || !encoded_key.start_with?(Sfb::Sealedkv::KEY_PREFIX)
          raise(ArgumentError, "invalid sealedkv key encoding")
        end

        encoded_raw_key = encoded_key.delete_prefix(Sfb::Sealedkv::KEY_PREFIX)
        raw_key = begin
          Base64.strict_decode64(encoded_raw_key).b
        rescue ArgumentError
          raise(ArgumentError, "invalid sealedkv key base64")
        end

        if raw_key.bytesize != Sfb::Sealedkv::KEY_BYTES
          raise(ArgumentError, "sealedkv key must decode to #{Sfb::Sealedkv::KEY_BYTES} bytes")
        end

        if encode(raw_key) != encoded_key
          raise(ArgumentError, "invalid sealedkv key spelling")
        end

        raw_key
      end
    end

    module Frame
      PREFIX = "sealedkv-v1"

      def self.encode(project_name:, secret_name:, secret:)
        Sfb::Sealedkv.validate_name!("project name", project_name)
        Sfb::Sealedkv.validate_name!("secret name", secret_name)
        if secret.nil?
          raise(ArgumentError, "secret must not be nil")
        end

        "#{PREFIX}:#{project_name}:#{secret_name}\0".b + String(secret).b
      end

      def self.decode(project_name:, secret_name:, plaintext:)
        Sfb::Sealedkv.validate_name!("project name", project_name)
        Sfb::Sealedkv.validate_name!("secret name", secret_name)

        plaintext = String(plaintext).b
        expected_header = "#{PREFIX}:#{project_name}:#{secret_name}\0".b
        if !plaintext.start_with?(expected_header)
          raise("decrypted sealedkv frame does not match requested project and secret")
        end

        plaintext.byteslice(expected_header.bytesize, plaintext.bytesize - expected_header.bytesize)
      end
    end

    module Crypto
      def self.encrypt_value(project_name:, secret_name:, key:, secret:)
        frame = Frame.encode(project_name:, secret_name:, secret:)
        nonce = Sodium.random_bytes(Sfb::Sealedkv::NONCE_BYTES)
        "#{nonce}#{Sodium.encrypt(key:, nonce:, plaintext: frame)}".b
      end

      def self.decrypt_value(project_name:, secret_name:, key:, blob:)
        blob = String(blob).b
        minimum_size = Sfb::Sealedkv::NONCE_BYTES + Sfb::Sealedkv::MAC_BYTES
        if blob.bytesize < minimum_size
          raise(ArgumentError, "encrypted blob is too short: #{blob.bytesize} bytes")
        end

        nonce = blob.byteslice(0, Sfb::Sealedkv::NONCE_BYTES)
        ciphertext = blob.byteslice(Sfb::Sealedkv::NONCE_BYTES, blob.bytesize - Sfb::Sealedkv::NONCE_BYTES)
        plaintext = Sodium.decrypt(key:, nonce:, ciphertext:)
        Frame.decode(project_name:, secret_name:, plaintext:)
      end
    end

    class Sodium
      class << self
        attr_accessor(:library_handle, :functions, :ready)
      end

      # Guards the one-time, process-global libsodium init in .ensure_ready!
      INIT_MUTEX = Mutex.new

      def self.random_bytes(length)
        if length < 0
          raise(ArgumentError, "random byte length must be non-negative")
        end

        ensure_ready!
        out = Fiddle::Pointer.malloc([length, 1].max, Fiddle::RUBY_FREE)
        functions.fetch(:randombytes_buf).call(out, length)
        out[0, length].b
      end

      def self.encrypt(key:, nonce:, plaintext:)
        validate_key_and_nonce!(key:, nonce:)

        ensure_ready!
        plaintext = String(plaintext).b
        out_len = plaintext.bytesize + Sfb::Sealedkv::MAC_BYTES
        out = Fiddle::Pointer.malloc(out_len, Fiddle::RUBY_FREE)
        plaintext_ptr = pointer_for(plaintext)
        nonce_ptr = pointer_for(nonce)
        key_ptr = pointer_for(key)

        rc = functions.fetch(:crypto_secretbox_easy).call(
          out,
          plaintext_ptr,
          plaintext.bytesize,
          nonce_ptr,
          key_ptr
        )
        if rc != 0
          raise("libsodium secretbox encryption failed")
        end

        out[0, out_len].b
      end

      def self.decrypt(key:, nonce:, ciphertext:)
        validate_key_and_nonce!(key:, nonce:)

        ensure_ready!
        ciphertext = String(ciphertext).b
        if ciphertext.bytesize < Sfb::Sealedkv::MAC_BYTES
          raise(ArgumentError, "ciphertext is too short for libsodium secretbox")
        end

        out_len = ciphertext.bytesize - Sfb::Sealedkv::MAC_BYTES
        out = Fiddle::Pointer.malloc([out_len, 1].max, Fiddle::RUBY_FREE)
        ciphertext_ptr = pointer_for(ciphertext)
        nonce_ptr = pointer_for(nonce)
        key_ptr = pointer_for(key)

        rc = functions.fetch(:crypto_secretbox_open_easy).call(
          out,
          ciphertext_ptr,
          ciphertext.bytesize,
          nonce_ptr,
          key_ptr
        )
        if rc != 0
          raise("libsodium secretbox decryption failed")
        end

        out[0, out_len].b
      end

      def self.ensure_ready!
        return if ready

        INIT_MUTEX.synchronize do
          next if ready

          self.library_handle = load_library
          self.functions = bind_functions(library_handle)

          rc = functions.fetch(:sodium_init).call
          if rc < 0
            raise("libsodium initialization failed")
          end

          assert_constants!
          self.ready = true
        end
      end

      def self.bind_functions(handle)
        {
          sodium_init: bind(handle, "sodium_init", [], Fiddle::TYPE_INT),
          randombytes_buf: bind(handle, "randombytes_buf", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T], Fiddle::TYPE_VOID),
          crypto_secretbox_keybytes: bind(handle, "crypto_secretbox_keybytes", [], Fiddle::TYPE_SIZE_T),
          crypto_secretbox_noncebytes: bind(handle, "crypto_secretbox_noncebytes", [], Fiddle::TYPE_SIZE_T),
          crypto_secretbox_macbytes: bind(handle, "crypto_secretbox_macbytes", [], Fiddle::TYPE_SIZE_T),
          crypto_secretbox_easy: bind(
            handle,
            "crypto_secretbox_easy",
            [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_ULONG_LONG, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
            Fiddle::TYPE_INT
          ),
          crypto_secretbox_open_easy: bind(
            handle,
            "crypto_secretbox_open_easy",
            [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_ULONG_LONG, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
            Fiddle::TYPE_INT
          ),
        }
      end

      def self.bind(handle, name, args, return_type)
        Fiddle::Function.new(handle[name], args, return_type)
      end

      def self.load_library
        Fiddle.dlopen("libsodium.so")
      rescue Fiddle::DLError => e
        raise("could not load libsodium.so; install the libsodium package: #{e.message}")
      end

      def self.assert_constants!
        expected = {
          crypto_secretbox_keybytes: Sfb::Sealedkv::KEY_BYTES,
          crypto_secretbox_noncebytes: Sfb::Sealedkv::NONCE_BYTES,
          crypto_secretbox_macbytes: Sfb::Sealedkv::MAC_BYTES,
        }

        expected.each do |function_name, expected_size|
          actual_size = functions.fetch(function_name).call
          if actual_size != expected_size
            raise("libsodium #{function_name} returned #{actual_size}, expected #{expected_size}")
          end
        end
      end

      def self.validate_key_and_nonce!(key:, nonce:)
        if String(key).bytesize != Sfb::Sealedkv::KEY_BYTES
          raise(ArgumentError, "secretbox key must be #{Sfb::Sealedkv::KEY_BYTES} bytes")
        end

        if String(nonce).bytesize != Sfb::Sealedkv::NONCE_BYTES
          raise(ArgumentError, "secretbox nonce must be #{Sfb::Sealedkv::NONCE_BYTES} bytes")
        end
      end

      def self.pointer_for(bytes)
        bytes = String(bytes).b
        pointer = Fiddle::Pointer.malloc([bytes.bytesize, 1].max, Fiddle::RUBY_FREE)
        pointer[0, bytes.bytesize] = bytes if bytes.bytesize.positive?
        pointer
      end
    end
  end
end
