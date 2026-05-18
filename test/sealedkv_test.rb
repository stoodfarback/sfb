# frozen_string_literal: true

require_relative("urpc_test_helper")

class SealedkvTest < Minitest::Test
  def teardown
    Sfb::Sealedkv.reset!
  end

  class BlobServer
    attr_accessor(:blobs)

    def initialize(blobs)
      self.blobs = blobs
    end

    def get_secret(project_name:, secret_name:)
      key = [project_name, secret_name]
      blob = blobs.fetch(key)
      if blob.is_a?(Array)
        next_blob = blob.shift
        raise("secret not found: #{project_name}/#{secret_name}") if !next_blob

        return(next_blob)
      end

      blob
    rescue KeyError
      raise("secret not found: #{project_name}/#{secret_name}")
    end
  end

  def test_get_discovers_identity_from_nested_working_directory_and_reads_exact_bytes
    Dir.mktmpdir("sfb-sealedkv") do |dir|
      key = Sfb::Sealedkv::Sodium.random_bytes(Sfb::Sealedkv::KEY_BYTES)
      write_identity(dir, project_name: "proj", key:)
      secret = "secret\0bytes\n\xff".b
      blob = encrypted_blob(project_name: "proj", secret_name: "api_key", key:, secret:)

      with_broker do
        start_server(Sfb::Sealedkv::RPC_KEY, BlobServer.new({ ["proj", "api_key"] => blob }))
        wait_for_backend(Sfb::Sealedkv::RPC_KEY)

        nested_dir = File.join(dir, "nested")
        Dir.mkdir(nested_dir)
        with_chdir(nested_dir) do
          assert_equal(secret, Sfb::Sealedkv.get("api_key"))
        end
      end
    end
  end

  def test_get_discovers_identity_from_immediate_caller_file_before_working_directory
    Dir.mktmpdir("sfb-sealedkv") do |root_dir|
      project_dir = File.join(root_dir, "project")
      caller_dir = File.join(project_dir, "lib")
      cwd_dir = File.join(root_dir, "cwd")
      Dir.mkdir(project_dir)
      Dir.mkdir(caller_dir)
      Dir.mkdir(cwd_dir)

      key = Sfb::Sealedkv::Sodium.random_bytes(Sfb::Sealedkv::KEY_BYTES)
      write_identity(project_dir, project_name: "callerproj", key:)
      caller = load_sealedkv_caller(caller_dir)
      secret = "from caller"
      blob = encrypted_blob(project_name: "callerproj", secret_name: "api_key", key:, secret:)

      with_broker do
        start_server(Sfb::Sealedkv::RPC_KEY, BlobServer.new({ ["callerproj", "api_key"] => blob }))
        wait_for_backend(Sfb::Sealedkv::RPC_KEY)

        with_chdir(cwd_dir) do
          assert_equal(secret, caller.get_secret("api_key"))
        end
      end
    end
  end

  def test_get_falls_back_to_working_directory_when_caller_tree_has_no_identity
    Dir.mktmpdir("sfb-sealedkv") do |root_dir|
      caller_root_dir = File.join(root_dir, "caller")
      caller_dir = File.join(caller_root_dir, "lib")
      cwd_project_dir = File.join(root_dir, "cwd_project")
      Dir.mkdir(caller_root_dir)
      Dir.mkdir(caller_dir)
      Dir.mkdir(cwd_project_dir)

      key = Sfb::Sealedkv::Sodium.random_bytes(Sfb::Sealedkv::KEY_BYTES)
      write_identity(cwd_project_dir, project_name: "cwdproj", key:)
      caller = load_sealedkv_caller(caller_dir)
      secret = "from cwd"
      blob = encrypted_blob(project_name: "cwdproj", secret_name: "token", key:, secret:)

      with_broker do
        start_server(Sfb::Sealedkv::RPC_KEY, BlobServer.new({ ["cwdproj", "token"] => blob }))
        wait_for_backend(Sfb::Sealedkv::RPC_KEY)

        with_chdir(cwd_project_dir) do
          assert_equal(secret, caller.get_secret("token"))
        end
      end
    end
  end

  def test_get_does_not_cache_successful_reads
    Dir.mktmpdir("sfb-sealedkv") do |dir|
      key = Sfb::Sealedkv::Sodium.random_bytes(Sfb::Sealedkv::KEY_BYTES)
      write_identity(dir, project_name: "proj", key:)
      blobs = [
        encrypted_blob(project_name: "proj", secret_name: "token", key:, secret: "first"),
        encrypted_blob(project_name: "proj", secret_name: "token", key:, secret: "second"),
      ]

      with_broker do
        start_server(Sfb::Sealedkv::RPC_KEY, BlobServer.new({ ["proj", "token"] => blobs }))
        wait_for_backend(Sfb::Sealedkv::RPC_KEY)

        with_chdir(dir) do
          assert_equal("first", Sfb::Sealedkv.get("token"))
          assert_equal("second", Sfb::Sealedkv.get("token"))
        end
      end
    end
  end

  def test_get_caches_identity_by_immediate_caller_file
    Dir.mktmpdir("sfb-sealedkv") do |root_dir|
      cwd_dir = File.join(root_dir, "cwd")
      project_a_dir = File.join(root_dir, "project_a")
      project_b_dir = File.join(root_dir, "project_b")
      caller_a_dir = File.join(project_a_dir, "lib")
      caller_b_dir = File.join(project_b_dir, "lib")
      Dir.mkdir(cwd_dir)
      Dir.mkdir(project_a_dir)
      Dir.mkdir(project_b_dir)
      Dir.mkdir(caller_a_dir)
      Dir.mkdir(caller_b_dir)

      key_a = Sfb::Sealedkv::Sodium.random_bytes(Sfb::Sealedkv::KEY_BYTES)
      key_b = Sfb::Sealedkv::Sodium.random_bytes(Sfb::Sealedkv::KEY_BYTES)
      write_identity(project_a_dir, project_name: "proja", key: key_a)
      write_identity(project_b_dir, project_name: "projb", key: key_b)
      caller_a = load_sealedkv_caller(caller_a_dir)
      caller_b = load_sealedkv_caller(caller_b_dir)

      blobs = {
        ["proja", "token"] => encrypted_blob(project_name: "proja", secret_name: "token", key: key_a, secret: "first"),
        ["projb", "token"] => encrypted_blob(project_name: "projb", secret_name: "token", key: key_b, secret: "second"),
      }

      with_broker do
        start_server(Sfb::Sealedkv::RPC_KEY, BlobServer.new(blobs))
        wait_for_backend(Sfb::Sealedkv::RPC_KEY)

        with_chdir(cwd_dir) do
          assert_equal("first", caller_a.get_secret("token"))
          File.binwrite(
            File.join(project_a_dir, Sfb::Sealedkv::CONFIG_FILE),
            JSON.generate({ "project" => "proja", "key" => "not-a-sealedkv-key" })
          )

          assert_equal("second", caller_b.get_secret("token"))
          assert_equal("first", caller_a.get_secret("token"))
        end
      end
    end
  end

  def test_get_raises_when_secret_is_missing
    Dir.mktmpdir("sfb-sealedkv") do |dir|
      key = Sfb::Sealedkv::Sodium.random_bytes(Sfb::Sealedkv::KEY_BYTES)
      write_identity(dir, project_name: "proj", key:)

      with_broker do
        start_server(Sfb::Sealedkv::RPC_KEY, BlobServer.new({}))
        wait_for_backend(Sfb::Sealedkv::RPC_KEY)

        with_chdir(dir) do
          error = assert_raises(RuntimeError) { Sfb::Sealedkv.get("missing") }
          assert_includes(error.message, "secret not found: proj/missing")
        end
      end
    end
  end

  def test_get_validates_secret_name_before_identity_lookup
    Dir.mktmpdir("sfb-sealedkv") do |dir|
      with_chdir(dir) do
        error = assert_raises(ArgumentError) { Sfb::Sealedkv.get("bad.name") }
        assert_includes(error.message, "invalid secret name")
      end
    end
  end

  def test_get_fails_before_urpc_when_identity_is_missing_or_invalid
    Dir.mktmpdir("sfb-sealedkv") do |dir|
      with_chdir(dir) do
        missing_error = assert_raises(RuntimeError) { Sfb::Sealedkv.get("token") }
        assert_includes(missing_error.message, "no #{Sfb::Sealedkv::CONFIG_FILE} found")
      end

      File.binwrite(
        File.join(dir, Sfb::Sealedkv::CONFIG_FILE),
        JSON.generate({ "project" => "proj", "key" => "not-a-sealedkv-key" })
      )

      with_chdir(dir) do
        invalid_error = assert_raises(ArgumentError) { Sfb::Sealedkv.get("token") }
        assert_includes(invalid_error.message, "invalid sealedkv key encoding")
      end
    end
  end

  def test_tampered_blob_and_mismatched_frame_fail_clearly
    key = Sfb::Sealedkv::Sodium.random_bytes(Sfb::Sealedkv::KEY_BYTES)
    blob = encrypted_blob(project_name: "proj", secret_name: "token", key:, secret: "value")

    tampered = blob.dup
    tampered.setbyte(tampered.bytesize - 1, tampered.getbyte(tampered.bytesize - 1) ^ 0xff)
    decrypt_error = assert_raises(RuntimeError) do
      Sfb::Sealedkv::Crypto.decrypt_value(project_name: "proj", secret_name: "token", key:, blob: tampered)
    end
    assert_includes(decrypt_error.message, "decryption failed")

    frame_error = assert_raises(RuntimeError) do
      Sfb::Sealedkv::Crypto.decrypt_value(project_name: "proj", secret_name: "other", key:, blob:)
    end
    assert_includes(frame_error.message, "frame")
  end

  def test_sodium_validates_inputs_before_loading_libsodium
    Sfb::Sealedkv::Sodium.stub(:ensure_ready!, -> { raise("should not load libsodium") }) do
      error = assert_raises(ArgumentError) do
        Sfb::Sealedkv::Sodium.encrypt(key: "x", nonce: "y", plaintext: "z")
      end
      assert_includes(error.message, "secretbox key must be")

      error = assert_raises(ArgumentError) do
        Sfb::Sealedkv::Sodium.decrypt(key: "x", nonce: "y", ciphertext: "z")
      end
      assert_includes(error.message, "secretbox key must be")

      error = assert_raises(ArgumentError) do
        Sfb::Sealedkv::Sodium.random_bytes(-1)
      end
      assert_includes(error.message, "random byte length must be non-negative")
    end
  end

  def write_identity(dir, project_name:, key:)
    path = File.join(dir, Sfb::Sealedkv::CONFIG_FILE)
    File.binwrite(
      path,
      JSON.pretty_generate({
        "project" => project_name,
        "key" => Sfb::Sealedkv::KeyEncoding.encode(key),
      }) + "\n"
    )
    File.chmod(0o600, path)
    path
  end

  def encrypted_blob(project_name:, secret_name:, key:, secret:)
    Sfb::Sealedkv::Crypto.encrypt_value(project_name:, secret_name:, key:, secret:)
  end

  def load_sealedkv_caller(dir)
    path = File.join(dir, "sealedkv_caller.rb")
    File.binwrite(path, <<~RUBY)
      $sfb_sealedkv_test_callers ||= {}
      $sfb_sealedkv_test_callers[__FILE__] = Module.new do
        def self.get_secret(secret_name)
          Sfb::Sealedkv.get(secret_name)
        end
      end
    RUBY
    load(path)
    $sfb_sealedkv_test_callers.fetch(path)
  end

  def with_chdir(dir)
    original_dir = Dir.pwd
    Dir.chdir(dir)
    yield
  ensure
    Dir.chdir(original_dir) if original_dir
  end
end
