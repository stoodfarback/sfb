# frozen_string_literal: true

require_relative("test_helper")

class TestMemo < Minitest::Test
  class Mem1
    extend(Sfb::Memo)

    def foo
      @one ||= 3; @one *= 2
    end

    memo def bar
      @two ||= 5; @two *= 2
    end

    memo memo def baz
      @three ||= 13; @three *= 2
    end
  end

  class Mem2 < Mem1
    def foo
      @one ||= 7; @one *= 2
    end

    memo def bar
      @two ||= 11; @two *= 2
    end
  end

  class Mem3 < Mem2
    def bar
      super * 11
    end
  end

  class Mem4 < Mem2
    memo def bar
      @two2 ||= super
      @two2 *= 13
    end
  end

  class Mem5 < Mem4
    memo def bar
      @two2 ||= super
      @two2 *= 17
    end
  end

  def test_basic
    mem1 = Mem1.new
    mem2 = Mem2.new
    mem3 = Mem3.new
    mem4 = Mem4.new
    mem5 = Mem5.new

    assert_equal(6, mem1.foo)
    assert_equal(12, mem1.foo)
    assert_equal(14, mem2.foo)
    assert_equal(28, mem2.foo)

    assert_equal(10, mem1.bar)
    assert_equal(10, mem1.bar)

    assert_equal(26, mem1.baz)
    assert_equal(26, mem1.baz)

    assert_equal(22, mem2.bar)
    assert_equal(22, mem2.bar)

    assert_equal(242, mem3.bar)
    assert_equal(242, mem3.bar)

    assert_equal(286, mem4.bar)
    assert_equal(286, mem4.bar)

    assert_equal(4862, mem5.bar)
    assert_equal(4862, mem5.bar)
  end
end
