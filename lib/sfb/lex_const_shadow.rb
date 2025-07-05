# frozen_string_literal: true

require("method_source")

module Sfb::LexConstShadow
  # Call this method once your subclass has finished defining constants that shadow
  # superclass constants. It will copy down any inherited methods that perform a
  # *lexical* constant lookup (e.g., `Sub.check`) so that these methods resolve
  # to the subclass's newly defined constants instead of the superclass's.
  #
  # Works for both instance and singleton methods.
  #
  # Why not just use `self::Sub` or `const_get(:Sub)` in superclass methods?
  # - Requires changing superclass source, making it noisier and less natural.
  # - Easy to miss some references, causing subtle bugs.
  # - Slightly slower, especially with JIT
  #
  # Why not manually redefine methods in each subclass?
  # - Manual work required to identify which methods need copying.
  # - Easy to forget updating subclasses when superclass methods change.
  #
  # Example:
  #
  #   class A
  #     def self.what = Sub.check
  #     class Sub; def self.check = :a end
  #   end
  #
  #   class B < A
  #     class Sub; def self.check = :b end
  #   end
  #
  #   class C < A
  #     class Sub; def self.check = :c end
  #     Sfb::LexConstShadow.redef!(self)
  #   end
  #
  #   class D < B
  #     Sfb::LexConstShadow.redef!(self)
  #   end
  #
  #   A.what # => :a   (A::Sub)
  #   B.what # => :a   (still A::Sub; method not copied yet)
  #   C.what # => :c   (copied method binds to C::Sub)
  #   D.what # => :b   (copied method binds to B::Sub)

  if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.4")
    raise("Ruby >= 3.4 required, got #{RUBY_VERSION}")
  end

  if !defined?(RubyVM::InstructionSequence)
    raise("CRuby required")
  end

  def self.redef!(klass)
    if !klass.is_a?(Class)
      raise("expected a Class but got #{klass.class}")
    end

    shadow_set = compute_shadows(klass)
    if shadow_set.empty?
      raise("expected at least one shadow constant")
    end

    seen = {}
    candidates = []
    collect = ->(container, kind) do
      (container.instance_methods(false) + container.private_instance_methods(false)).each do |meth|
        key = [container, meth, kind]
        next if seen[key]
        seen[key] = true

        um = container.instance_method(meth)
        next unless lexical_read?(um, shadow_set)

        already =
          if kind == :instance
            klass.instance_methods(false) + klass.private_instance_methods(false)
          else
            klass.singleton_class.instance_methods(false) +
              klass.singleton_class.private_instance_methods(false)
          end
        next if already.include?(meth)

        candidates << [um, meth, kind]
      end
    end

    # 1 — walk normal ancestors
    klass.ancestors.drop(1).each do |mod|
      collect.(mod, :instance) # instance / included mix-ins
      collect.(mod.singleton_class, :singleton) # def self.foo on superclasses
    end

    # 2 — walk singleton-class ancestors to catch `extend`ed modules
    klass.singleton_class.ancestors.drop(1).each do |sca|
      next if sca.is_a?(Class) # skip anonymous singleton classes
      collect.(sca, :singleton) # true owner is a Module
    end

    if candidates.empty?
      raise("no methods required redef")
    end

    candidates.each do |um, meth, kind|
      copy_method!(klass, um, meth, kind)
    end

    nil
  end

  def self.compute_shadows(klass)
    const_defs = {}

    klass.ancestors.
      take_while {|mod| mod != Object && mod != BasicObject }.
      reverse_each do |ancestor|

      next unless ancestor.respond_to?(:constants)

      ancestor.constants(false).each do |c|
        begin
          val = ancestor.const_get(c, false)
        rescue NameError
          next
        end

        if const_defs.key?(c)
          const_defs[c][1] = val
        else
          const_defs[c] = [val, val]
        end
      end
    end

    shadow_set = const_defs.select do |_, (first, last)|
      !first.equal?(last)
    end.keys

    shadow_set.select! {|c| klass.const_defined?(c, false) || klass.const_defined?(c) }

    shadow_set.to_set.freeze
  end

  OPCODES = %i[opt_getconstant_path opt_getconstant_path_at].freeze

  def self.lexical_read?(umethod, shadow_set)
    iseq = RubyVM::InstructionSequence.of(umethod)
    return false if !iseq

    stack = [iseq]
    until stack.empty?
      node = stack.pop
      body = node.to_a.last

      body.each do |insn|
        next if !insn.is_a?(Array)

        op = insn[0]
        arg = insn[1]
        next if !OPCODES.include?(op)
        next if !arg.is_a?(Array) || arg.empty?
        next if arg.first == :""

        return true if shadow_set.include?(arg.first)
      end
      node.each_child {|child| stack << child }
    end

    false
  end

  def self.copy_method!(klass, umethod, meth_name, kind)
    code, file, line = def_source_via_iseq(umethod)
    if !code
      begin
        # try fallback
        code = umethod.source
        file, line = umethod.source_location
      rescue MethodSource::SourceNotFoundError
        raise("cannot copy #{umethod.owner}##{meth_name} - source unavailable (block/eval/C-ext)")
      end
    end

    if !code.lstrip.start_with?("def ")
      raise("cannot copy #{umethod.owner}##{meth_name} - unusual source code situation; expected def, got #{code.lstrip[0, 50].inspect}")
    end

    visibility =
      if umethod.owner.private_method_defined?(meth_name)
        :private
      elsif umethod.owner.protected_method_defined?(meth_name)
        :protected
      else
        :public
      end

    if kind == :singleton
      if code.lstrip.match?(/\Adef\s+self\./)
        klass.class_eval(code, file, line)
      else
        wrapped = "class << self\n  #{code.lines.map(&:chomp).join("\n  ")}\nend"
        klass.class_eval(wrapped, file, line)
      end
      klass.singleton_class.send(visibility, meth_name)
    else
      klass.class_eval(code, file, line)
      klass.send(visibility, meth_name)
    end
  end

  def self.def_source_via_iseq(umethod)
    iseq = RubyVM::InstructionSequence.of(umethod) or return
    meta = iseq.to_a[4] # header-hash
    loc = meta[:code_location] rescue nil # [l1,c1,l2,c2]
    return if !loc

    l1, c1, l2, c2 = loc
    file = iseq.absolute_path || umethod.source_location.first
    lines = File.readlines(file, chomp: false)

    if l1 == l2
      snippet = lines[l1 - 1][c1...c2]
    else
      snippet  = lines[l1 - 1][c1..]
      snippet << lines[(l1)...(l2 - 1)].join
      snippet << lines[l2 - 1][0...c2]
    end

    [snippet, file, l1]
  rescue Errno::ENOENT
    nil
  end
end
