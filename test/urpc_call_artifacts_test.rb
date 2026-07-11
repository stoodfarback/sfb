# frozen_string_literal: true

require_relative("test_helper")

class UrpcCallArtifactsTest < Minitest::Test
  def test_file_backed_output_artifacts
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      submission = build_submission(file_backed: true)
      id = submission.id

      artifacts = Urpc::CallArtifacts.prepare(paths, submission)

      assert_equal(submission.payload, File.binread(paths.call_file(id)))
      assert(File.lstat(paths.output_fifo(id)).pipe?)
      assert_equal(false, File.exist?(paths.input_fifo(id)))
      assert(artifacts.output_io.stat.pipe?)

      writer = File.open(paths.output_fifo(id), File::WRONLY | File::NONBLOCK)
      writer.write_nonblock("x")

      assert(artifacts.output_io.wait_readable(1))
      assert_equal("x", artifacts.output_io.read_nonblock(1))
    ensure
      close_io(writer)
      close_io(artifacts)
    end
  end

  def test_cast_artifacts_create_no_output
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      submission = build_submission(cast: true)
      id = submission.id

      artifacts = Urpc::CallArtifacts.prepare(paths, submission)

      assert_nil(artifacts.output_io)
      assert_equal(false, File.exist?(paths.call_file(id)))
      assert_equal(false, File.exist?(paths.output_fifo(id)))
      assert_equal(false, File.exist?(paths.input_fifo(id)))
    end
  end

  def test_bidirectional_artifacts_create_input_without_opening_it
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      submission = build_submission(bidirectional: true)
      id = submission.id

      artifacts = Urpc::CallArtifacts.prepare(paths, submission)

      assert(File.lstat(paths.output_fifo(id)).pipe?)
      assert(File.lstat(paths.input_fifo(id)).pipe?)
      assert_raises(Errno::ENXIO) { File.open(paths.input_fifo(id), File::WRONLY | File::NONBLOCK) }
    ensure
      close_io(artifacts)
    end
  end

  def test_close_does_not_unlink_paths
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      submission = build_submission(file_backed: true, bidirectional: true)
      id = submission.id

      artifacts = Urpc::CallArtifacts.prepare(paths, submission)
      artifacts.close

      assert_equal(submission.payload, File.binread(paths.call_file(id)))
      assert(File.lstat(paths.output_fifo(id)).pipe?)
      assert(File.lstat(paths.input_fifo(id)).pipe?)
    end
  end

  def test_cleanup_submission_failure_closes_output_and_unlinks_created_paths
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      submission = build_submission(file_backed: true, bidirectional: true)
      id = submission.id

      artifacts = Urpc::CallArtifacts.prepare(paths, submission)
      artifacts.cleanup_submission_failure!

      assert(artifacts.output_io.closed?)
      assert_equal(false, File.exist?(paths.call_file(id)))
      assert_equal(false, File.exist?(paths.output_fifo(id)))
      assert_equal(false, File.exist?(paths.input_fifo(id)))
    end
  end

  def test_prepare_rolls_back_created_paths_after_failure
    with_urpc_root do
      paths = Urpc::ServiceDir.new("svc").prepare!
      submission = build_submission(file_backed: true)
      id = submission.id
      File.write(paths.output_fifo(id), "preexisting")

      assert_raises(Errno::EEXIST) do
        Urpc::CallArtifacts.prepare(paths, submission)
      end

      assert_equal(false, File.exist?(paths.call_file(id)))
      assert_equal("preexisting", File.read(paths.output_fifo(id)))
    end
  end

  def build_submission(cast: false, bidirectional: false, file_backed: false)
    value = file_backed ? "x" * (Urpc::SubmitFrame::INLINE_PAYLOAD_LEN_MAX + 1) : "payload"
    Urpc::SubmitFrame::Submission.build(:call, [value], {}, cast:, bidirectional:)
  end
end
