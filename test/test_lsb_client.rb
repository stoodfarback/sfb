# frozen_string_literal: true

require_relative("test_helper")

class TestLsbClient < Minitest::Test
  def test_basic
    project_name = "sfb"
    project_id = "nzsdzv5zd7r5kcf8prbxyhzics10fm92rp07gbyu5mktyfzv49"
    client = Sfb::LsbClient.new(project_id:, project_name:)
    assert_equal("pong", client.fetch("ping"))
  end
end
