# frozen_string_literal: true

require_relative("test_helper")

class UrpcFifoTest < Minitest::Test
  def test_create_and_open_real_fifo
    Dir.mktmpdir do |dir|
      path = File.join(dir, "transport.fifo")

      assert_equal(path, Urpc::Fifo.create(path))
      assert(File.lstat(path).pipe?)
      assert_equal(0o600, File.stat(path).mode & 0o777)

      reader = Urpc::Fifo.open(path, File::RDONLY | File::NONBLOCK)
      writer = Urpc::Fifo.open(path, File::WRONLY | File::NONBLOCK)
      assert_equal(5, writer.write_nonblock("hello"))
      assert(reader.wait_readable(1))
      assert_equal("hello", reader.read_nonblock(5))
    ensure
      close_io(reader)
      close_io(writer)
    end
  end

  def test_open_rejects_regular_file_without_changing_it
    Dir.mktmpdir do |dir|
      path = File.join(dir, "not-a-fifo")
      File.write(path, "contents")

      error = assert_raises(RuntimeError) { Urpc::Fifo.open(path, File::WRONLY | File::NONBLOCK) }

      assert_equal("#{path} is not a FIFO", error.message)
      assert_equal("contents", File.read(path))
    end
  end

  def test_verify_path_rejects_regular_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "not-a-fifo")
      File.write(path, "contents")

      error = assert_raises(RuntimeError) { Urpc::Fifo.verify_path!(path) }

      assert_equal("#{path} is not a FIFO", error.message)
    end
  end
end
