module Sfb::Memo
  def memo(method_name)
    method_name_s = method_name.to_s
    stripped_method_name = method_name_s.sub(/([!?])$/, "")

    punctuation = $1
    wordy_punctuation = (punctuation == "!" ? "_bang" : "_huh") if punctuation
    ivar_name = "@#{stripped_method_name}#{wordy_punctuation}"

    memoized_method_name = "#{stripped_method_name}_with_memo#{punctuation}"
    regular_method_name  = "#{stripped_method_name}_without_memo#{punctuation}"

    if !(instance_methods + private_instance_methods).include?(method_name)
      raise(NoMethodError, "The Method '#{method_name}' cannot be memoized because it doesn't exist in #{self}")
    end
    return if self.method_defined?(memoized_method_name)

    raise("#memo only works for zero-arity methods") if instance_method(method_name).arity != 0

    class_eval(<<~HEREDOC, __FILE__, __LINE__ + 1)
      def #{memoized_method_name}
        if defined?(#{ivar_name})
          #{ivar_name}
        else
          #{ivar_name} = #{regular_method_name}
        end
      end
      alias_method(:#{regular_method_name}, :#{method_name})
      alias_method(:#{method_name}, :#{memoized_method_name})
      protected(:#{method_name}) if protected_instance_methods.include?(:#{regular_method_name})
      private(:#{method_name}) if private_instance_methods.include?(:#{regular_method_name})
    HEREDOC
    method_name
  end
end
