# frozen_string_literal: true

require_relative("test_helper")

class LexConstShadowTest < Minitest::Test
  # preload so we can safely remove_const in teardown
  Sfb::LexConstShadow.name

  def teardown
    super
    if @tmp_dir && Dir.exist?(@tmp_dir)
      FileUtils.remove_entry(@tmp_dir)
      @tmp_dir = nil
    end
    if @consts_to_undef
      @consts_to_undef.uniq.each do |c|
        Object.send(:remove_const, c)
      end
      @consts_to_undef.clear
    end
  end

  def define_test_class(definition)
    @tmp_dir ||= Dir.mktmpdir
    @@define_test_class_count ||= 0
    count = (@@define_test_class_count += 1)
    @consts_to_undef ||= []
    file = File.join(@tmp_dir, "test_class_#{count.to_s.rjust(3, "0")}.rb")
    File.write(file, <<~RUBY)
      # frozen_string_literal: true

      #{definition}
    RUBY
    consts_before = Object.constants
    load(file)
  ensure
    consts_after = Object.constants
    @consts_to_undef += consts_after - consts_before
  end

  def test_meta_clean_define_test_class_1
    define_test_class(<<~RUBY)
      class A
        def self.one = 1
      end
    RUBY
    assert_equal(1, A.one)
    assert(!A.singleton_methods.include?(:two))
  end

  def test_meta_clean_define_test_class_2
    define_test_class(<<~RUBY)
      class A
        def self.two = 2
      end
    RUBY
    assert_equal(2, A.two)
    assert(!A.singleton_methods.include?(:one))
  end

  def test_meta_clean_define_test_class_3
    assert_raises do
      define_test_class(<<~RUBY)
        class A
          def self.one = 1
          def self.two = 2
          raise
        end
      RUBY
    end
  end

  def test_basic
    define_test_class(<<~RUBY)
      class A
        def self.what = Sub.check
        class Sub; def self.check = :a end
      end

      class B < A
        class Sub; def self.check = :b end
      end

      class C < A
        class Sub; def self.check = :c end
        Sfb::LexConstShadow.redef!(self)
      end

      class D < B
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY
    assert_equal(:a, A.what)
    assert_equal(:a, B.what)
    assert_equal(:c, C.what)
    assert_equal(:b, D.what)
  end

  def test_instance_method_rebound
    define_test_class(<<~RUBY)
      class InstBase
        def who = Sub.check

        class Sub
          def self.check = :base
        end
      end

      class InstChild < InstBase
        class Sub
          def self.check = :child
        end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(:child, InstChild.new.who)
  end

  def test_default_argument_rebound
    define_test_class(<<~RUBY)
      class DefaultArgBase
        def self.call(x = Sub.check) = x

        class Sub
          def self.check = :base
        end
      end

      class DefaultArgSub < DefaultArgBase
        class Sub
      def self.check = :shadow
        end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(:shadow, DefaultArgSub.())
  end

  def test_self_colon_does_not_rebind
    assert_raises do
      define_test_class(<<~RUBY)
        class ExplicitLookupBase
          def self.call = self::Sub.check

          class Sub
            def self.check = :base
          end
        end

        class ExplicitLookupChild < ExplicitLookupBase
          class Sub
            def self.check = :child
          end
          Sfb::LexConstShadow.redef!(self)
        end
      RUBY
    end
  end

  def test_manual_override_survives
    assert_raises do
      define_test_class(<<~RUBY)
        class OverrideBase
          def self.what = Sub.check

          class Sub
            def self.check = :base
          end
        end

        class OverrideChild < OverrideBase
          def self.what = :manual

          class Sub
            def self.check = :shadow
          end
          Sfb::LexConstShadow.redef!(self)
        end
      RUBY
    end
  end

  def test_no_shadow_raises
    assert_raises do
      define_test_class(<<~RUBY)
        class NoShadowBase
          CONST = :x
        end

        class NoShadowChild < NoShadowBase
          Sfb::LexConstShadow.redef!(self)
        end
      RUBY
    end
  end

  def test_alias_not_shadow
    assert_raises do
      define_test_class(<<~RUBY)
        class AliasBase
          class Sub; end
        end

        class AliasChild < AliasBase
          Sub = AliasBase::Sub
          Sfb::LexConstShadow.redef!(self)
        end
      RUBY
    end
  end

  def test_source_less_method_raises
    assert_raises do
      define_test_class(<<~RUBY)
        class SourceLessBase
          define_singleton_method(:bad) { Sub.check }

          class Sub
            def self.check = :x
          end
        end

        class SourceLessChild < SourceLessBase
          class Sub
            def self.check = :y
          end
          Sfb::LexConstShadow.redef!(self)
        end
      RUBY
    end
  end

  def test_deep_inheritance
    define_test_class(<<~RUBY)
      class DeepA
        def self.klass = Sub.name
        class Sub; end
      end

      class DeepB < DeepA
        class Sub; end
      end

      class DeepC < DeepB
        class Sub; end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal("DeepC::Sub", DeepC.klass)
  end

  def test_multiple_shadow_constants
    define_test_class(<<~RUBY)
      class DoubleShadowA
        def self.combo = [X, Y]
        X = 1
        Y = 2
      end

      class DoubleShadowB < DoubleShadowA
        X = "foo"
        Y = "bar"
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(%w[foo bar], DoubleShadowB.combo)
    assert_equal([1, 2], DoubleShadowA.combo)
  end

  def test_multiple_shadow_constants_in_default
    define_test_class(<<~RUBY)
      class DefaultManyA
        def self.pick(x = [X, Y]) = x
        X = :a
        Y = :b
      end

      class DefaultManyB < DefaultManyA
        X = :x
        Y = :y
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(%i[x y], DefaultManyB.pick)
  end

  def test_default_keyword_arg_rebound
    define_test_class(<<~RUBY)
      class KwargBase
        def self.val(x: Sub.check, **rest) = x
        class Sub
          def self.check = :kw
        end
      end

      class KwargChild < KwargBase
        class Sub
          def self.check = :child_kw
        end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(:child_kw, KwargChild.val)
  end

  def test_backtrace_refers_to_subclass_line
    define_test_class(<<~RUBY)
      class BacktraceBase
        def self.raise_me = Sub.raise_me
        class Sub
          def self.raise_me; raise("test_marker"); end
        end
      end

      class BacktraceChild < BacktraceBase
        class Sub
          def self.raise_me; raise("child_marker"); end
        end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    err = assert_raises(RuntimeError) { BacktraceChild.raise_me }
    assert_match(/child_marker/, err.message)
    file, _line = BacktraceChild.method(:raise_me).source_location
    assert(file && File.read(file)[/child_marker/], "should be subclass source line")
  end

  def test_sclass_singleton_rebound
    define_test_class(<<~RUBY)
      class SClassBase
        class << self
          def foo = Sub.val
        end
        class Sub
          def self.val = :base
        end
      end

      class SClassChild < SClassBase
        class Sub
          def self.val = :child
        end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(:child, SClassChild.foo)
  end

  def test_private_method_copied
    define_test_class(<<~RUBY)
      class PrivBase
        def self.pub = Sub.check
        def self.pri = Sub.check
        private_class_method(:pri)
        class Sub; def self.check = :pb end
      end

      class PrivChild < PrivBase
        class Sub; def self.check = :pc end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(:pc, PrivChild.pub)
    assert_equal(:pc, PrivChild.send(:pri))
    assert(PrivChild.private_methods.include?(:pri))
  end

  def test_private_method_copied_prefix
    define_test_class(<<~RUBY)
      class PrivBase2
        def self.pub = Sub.check
        private_class_method(def self.pri = Sub.check)
        class Sub; def self.check = :pb end
      end

      class PrivChild2 < PrivBase2
        class Sub; def self.check = :pc end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(:pc, PrivChild2.pub)
    assert_equal(:pc, PrivChild2.send(:pri))
    assert(PrivChild2.private_methods.include?(:pri))
  end

  def test_instance_lexical_rebound
    define_test_class(<<~RUBY)
      class InstLexBase
        def what = Sub.check
        class Sub; def self.check = :base end
      end

      class InstLexChild < InstLexBase
        class Sub; def self.check = :child end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(:child, InstLexChild.new.what)
  end

  def test_instance_default_arg
    define_test_class(<<~RUBY)
      class InstDefaultArgBase
        def get(x = Sub.check) = x
        class Sub; def self.check = :base end
      end

      class InstDefaultArgChild < InstDefaultArgBase
        class Sub; def self.check = :child end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(:child, InstDefaultArgChild.new.get)
  end

  def test_instance_nested_const
    define_test_class(<<~RUBY)
      class InstNestedConstBase
        def nested = Sub::X
        class Sub; X = :base_x end
      end

      class InstNestedConstChild < InstNestedConstBase
        class Sub; X = :child_x end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(:child_x, InstNestedConstChild.new.nested)
  end

  def test_instance_mixin_rebound
    define_test_class(<<~RUBY)
      module InstMixin
        def mix = Sub.check
      end

      class InstMixinBase
        include(InstMixin)
        class Sub; def self.check = :base end
      end

      class InstMixinChild < InstMixinBase
        class Sub; def self.check = :child end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(:child, InstMixinChild.new.mix)
  end

  def test_instance_override_skips_copy
    assert_raises do
      define_test_class(<<~RUBY)
        class OverrideInstBase
          def foo = Sub.name
          class Sub; end
        end

        class OverrideInstChild < OverrideInstBase
          def foo = :manual
          class Sub; end
          Sfb::LexConstShadow.redef!(self)
        end
      RUBY
    end

    assert_equal(:manual, OverrideInstChild.new.foo)
  end

  def test_private_instance_method
    define_test_class(<<~RUBY)
      class PrivInstBase
        def public_meth = [private_meth_1, private_meth_2, private_meth_3, private_meth_4, private_meth_5, private_meth_6]
        private def private_meth_1 = Sub.val
        private(def private_meth_2 = Sub.val)
        private def private_meth_3
          Sub.val
        end
        private(def private_meth_4
          Sub.val
        end)
        private
        def private_meth_5 = Sub.val
        def private_meth_6
          Sub.val
        end
        class Sub; def self.val = :base end
      end

      class PrivInstChild < PrivInstBase
        class Sub; def self.val = :child end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(%i[child child child child child child], PrivInstChild.new.public_meth)
    assert(PrivInstChild.private_instance_methods.include?(:private_meth_1))
    assert(PrivInstChild.private_instance_methods.include?(:private_meth_2))
    assert(PrivInstChild.private_instance_methods.include?(:private_meth_3))
    assert(PrivInstChild.private_instance_methods.include?(:private_meth_4))
    assert(PrivInstChild.private_instance_methods.include?(:private_meth_5))
    assert(PrivInstChild.private_instance_methods.include?(:private_meth_6))
  end

  def test_mixin_methods_rebound
    define_test_class(<<~RUBY)
      module MixinMod
        def get_sub; Sub.name; end
        class Sub; end
      end
      class ModBase
        extend(MixinMod)
        class Sub; end
      end
      class ModChild < ModBase
        class Sub; end
      end
      class ModChild2 < ModBase
        class Sub; end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal("MixinMod::Sub", ModChild.get_sub)
    assert_equal("ModChild2::Sub", ModChild2.get_sub)
  end

  def test_private_module_method_rebound
    define_test_class(<<~RUBY)
      module PrivateMixin
        private def hidden = Sub.flag
        class Sub; def self.flag = :base end
      end

      class PBase
        extend PrivateMixin
        class Sub; def self.flag = :base end
      end

      class PChild < PBase
        class Sub; def self.flag = :child end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY
    assert_equal(:child, PChild.send(:hidden))
    assert(PChild.private_methods.include?(:hidden))
  end

  def test_multiple_extended_mixins
    define_test_class(<<~RUBY)
      module M1
        def a = Sub.id
        class Sub; def self.id = :m1 end
      end
      module M2
        def b = Sub.id
        class Sub; def self.id = :m2 end
      end

      class EBase
        extend M1
        extend M2
        class Sub; def self.id = :base end
      end

      class EChild < EBase
        class Sub; def self.id = :child end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(:child, EChild.a)
    assert_equal(:child, EChild.b)
  end

  def test_multiple_defs_on_same_line
    define_test_class(<<~RUBY.lines.map(&:strip).join("; "))
      class A
        def self.one = Sub.id
        def self.two = Sub.id
        class Sub; def self.id = :base end
      end

      class B < A
        class Sub; def self.id = :child end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(:child, B.one)
    assert_equal(:child, B.two)
  end

  def test_multiple_defs_on_same_line_different_classes
    define_test_class(<<~RUBY.lines.map(&:strip).join("; "))
      class A
        def self.one = Sub.id
        def self.two = Sub.id
        class Sub; def self.id = :base end
      end

      class B < A
        def self.two = Sub.id
        class Sub; def self.id = :child end
        Sfb::LexConstShadow.redef!(self)
      end
    RUBY

    assert_equal(:child, B.one)
    assert_equal(:child, B.two)
  end

  def test_proc_reference_is_not_rebound
    define_test_class(<<~RUBY)
      class ProcBase
        Const = :from_proc
        L = -> { Const }
        def self.value = L.()
      end
      class ProcChild < ProcBase
        Const = :from_child
      end
    RUBY

    assert_equal(:from_proc, ProcChild.value)
    assert_raises { Sfb::LexConstShadow.redef!(ProcChild) }
  end

  def test_unrelated_method_not_copied
    assert_raises do
      define_test_class(<<~RUBY)
        class ExtraMethBase
          def self.alpha = "alpha"
          class Sub; end
        end
        class ExtraMethChild < ExtraMethBase
          class Sub; end
          Sfb::LexConstShadow.redef!(self)
        end
      RUBY
    end
  end

  # maybe handle aliases. later, not a priority atm
  # def test_method_alias_preserved
  #   define_test_class(<<~RUBY)
  #     class AliasMethodBase
  #       def self.orig = Sub.check
  #       class Sub; def self.check = :x end
  #     end
  #     class AliasMethodChild < AliasMethodBase
  #       class Sub; def self.check = :y end
  #       class << self; alias_method(:orig_alias, :orig); end
  #       Sfb::LexConstShadow.redef!(self)
  #     end
  #   RUBY

  #   assert_equal(:y, AliasMethodChild.orig)
  #   assert_equal(:y, AliasMethodChild.orig_alias)
  # end
end
