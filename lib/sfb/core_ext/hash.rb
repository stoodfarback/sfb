# frozen_string_literal: true

class Hash
  def same_keys?(other_hash)
    return(false) if size != other_hash.size
    each_key do |k|
      return(false) if !other_hash.include?(k)
    end
    true
  end
end
