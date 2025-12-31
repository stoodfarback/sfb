# frozen_string_literal: true

require_relative("test_helper")

class TestStore < Minitest::Test
  def test_basic
    path = File.expand_path(File.join(__dir__, "..", "tmp", "test_store_basic.yml"))
    if File.exist?(path)
      FileUtils.rm(path)
    end
    store = Sfb::Store.new(path)
    assert_nil(store[:one])

    assert_equal(1, store[:one] = 1)
    assert_equal(1, store[:one])
    assert_equal(2, store[:one] += 1)
    assert_equal(3, store[:one] += 1)
    assert_equal(3, store[:one])

    assert_equal("foo", store[:two] = "foo")
    assert_equal("foo", store[:two])

    assert_equal("1", store[:three] = "1")
    assert_equal("1", store[:three])

    data_raw = File.read(path)
    assert_equal(data_raw.strip, <<~HEREDOC.strip)
      ---
      :one: 3
      :two: foo
      :three: '1'
    HEREDOC

    # cache still has values even if file is gone
    FileUtils.rm(path)
    assert_equal(3, store[:one])
  end
end
