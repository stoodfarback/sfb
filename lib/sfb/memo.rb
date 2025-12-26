# frozen_string_literal: true

module Sfb::Memo
  def memo(method_name)
    method_name = method_name.to_sym

    if !method_defined?(method_name)
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
    mod = $sfb_memo_lookup[self] ||= begin
      mod = Module.new
      mod.set_temporary_name("Sfb::Memo(generated module)")
      self.prepend(mod)
      mod
    end

    mod.module_eval(<<~HEREDOC, __FILE__, __LINE__ + 1)
      def #{method_name}
        if defined?(#{ivar_name})
          #{ivar_name}
        else
          #{ivar_name} = super
        end
      end
    HEREDOC

    method_name
  end
end
