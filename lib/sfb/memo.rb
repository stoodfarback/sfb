# frozen_string_literal: true

module Sfb::Memo
  NOT_SET = Module.new

  def memo(method_name)
    method_name = method_name.to_sym

    if !instance_methods.include?(method_name)
      raise(NoMethodError, "#memo expected '#{method_name}' to be an instance method of #{self}")
    end

    method = instance_method(method_name)

    if method.arity != 0
      raise("#memo doesn't work for methods that take arguments")
    end

    my_source_location = method(__method__).source_location.first

    if method.source_location.first == my_source_location
      # the method definition location matches the current file, meaning it's already memoized
      # can happen if memo is called twice on the same method
      return(method_name)
    end

    method_name_base = method_name.to_s.sub(/([!?])$/, "")
    punctuation = $1
    if punctuation
      punctuation_word = (punctuation == "!" ? "_bang" : "_q")
    end
    ivar_name = "@#{method_name_base}#{punctuation_word}"

    # only prepend the generated module once per class instead of once per memo
    $sfb_memo_lookup ||= {}
    for_this_class = $sfb_memo_lookup[self] ||= begin
      mod = Module.new
      mod.set_temporary_name("Sfb::Memo(generated module)")
      init_params = instance_method(:initialize).arity == 0 ? "" : "(...)"
      mod.module_eval(<<~HEREDOC, __FILE__, __LINE__ + 1)
        NOT_SET = ::Sfb::Memo::NOT_SET
        def initialize#{init_params}
          init_memo_ivars
          super
        end
      HEREDOC
      self.prepend(mod)
      ivars = []
      { mod:, ivars: }
    end
    for_this_class => { mod:, ivars: }

    ivars << ivar_name

    mod.module_eval(<<~HEREDOC, __FILE__, __LINE__ + 1)
      def #{method_name}
        if #{ivar_name} != NOT_SET
          #{ivar_name}
        else
          #{ivar_name} = super
        end
      end
    HEREDOC

    if mod.method_defined?(:init_memo_ivars)
      mod.remove_method(:init_memo_ivars)
    end
    mod.module_eval(<<~HEREDOC, __FILE__, __LINE__ + 1)
      def init_memo_ivars
        #{ivars.map { "#{_1} = NOT_SET" }.join("\n") }
      end
    HEREDOC

    method_name
  end
end
