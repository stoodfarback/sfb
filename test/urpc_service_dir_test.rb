# frozen_string_literal: true

require_relative("test_helper")

class UrpcServiceDirTest < Minitest::Test
  def test_prepare_creates_service_directories_and_submit_fifo
    with_urpc_root do
      service = Urpc::ServiceDir.new("agent_mail_v1")

      paths = service.prepare!

      assert(File.directory?(paths.dir))
      assert(File.directory?(paths.calls_dir))
      assert(File.directory?(paths.output_dir))
      assert(File.directory?(paths.input_dir))
      assert(File.lstat(paths.submit_fifo).pipe?)
    end
  end

  def test_prepare_is_idempotent
    with_urpc_root do
      service = Urpc::ServiceDir.new("svc")

      service.prepare!
      inode = File.lstat(service.paths.submit_fifo).ino
      service.prepare!

      assert_equal(inode, File.lstat(service.paths.submit_fifo).ino)
    end
  end

  def test_prepare_rejects_non_fifo_submit_path
    with_urpc_root do
      service = Urpc::ServiceDir.new("svc")
      FileUtils.mkdir_p(service.paths.dir)
      File.write(service.paths.submit_fifo, "not a fifo")

      error = assert_raises(RuntimeError) { service.prepare! }

      assert_match(/not a FIFO/, error.message)
    end
  end

  def test_acquire_server_lock_holds_exclusive_lock
    with_urpc_root do
      service = Urpc::ServiceDir.new("svc")
      lock = service.acquire_server_lock!

      error = assert_raises(RuntimeError) { Urpc::ServiceDir.new("svc").acquire_server_lock! }
      assert_match(/already running/, error.message)

      lock.close
      second_lock = service.acquire_server_lock!
      second_lock.close
    ensure
      if lock && !lock.closed?
        lock.close
      end
    end
  end
end
