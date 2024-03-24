# frozen_string_literal: true

module Sfb::Memo
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

    method_name_nomo = :"#{method_name_base}_nomo#{punctuation}"

    workaround_for_super = false

    if defined?(method_name_nomo) &&
        method.super_method&.source_location&.first == my_source_location
      source = method.try(:source)
      if !source
        workaround_for_super = true
      else
        if source.include?("super")
          require("ripper")
          workaround_for_super = Ripper.tokenize(source).include?("super")
        end
      end
    end

    if workaround_for_super

      method_name_nomo_safe = nil
      (1..99).each do |i|
        maybe = :"#{method_name_base}_nomo_s#{i}#{punctuation}"
        if !instance_methods.include?(maybe)
          method_name_nomo_safe = maybe
          break
        end
      end
      raise("#memo internal error") if !method_name_nomo_safe

      class_eval(<<~HEREDOC, __FILE__, __LINE__ + 1)
        alias_method(:#{method_name_nomo_safe}, :#{method_name})
        alias_method(:#{method_name}, :#{method_name_nomo})
        def #{method_name}
          if defined?(#{ivar_name})
            #{ivar_name}
          else
            #{ivar_name} = #{method_name_nomo_safe}
          end
        end
      HEREDOC

      return(method_name)
    end

    class_eval(<<~HEREDOC, __FILE__, __LINE__ + 1)
      alias_method(:#{method_name_nomo}, :#{method_name})
      def #{method_name}
        if defined?(#{ivar_name})
          #{ivar_name}
        else
          #{ivar_name} = #{method_name_nomo}
        end
      end
    HEREDOC
    method_name
  end
end
