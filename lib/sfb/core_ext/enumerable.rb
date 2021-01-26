module Enumerable
  def sort_by_with_nils_first
    sort do |a, b|
      block_given? && a = yield(a)
      block_given? && b = yield(b)

      if !a && !b
        0
      elsif !b
        1
      elsif !a
        -1
      else
        a <=> b
      end
    end
  end

  def sort_by_with_nils_last
    sort do |a, b|
      block_given? && a = yield(a)
      block_given? && b = yield(b)

      if !a && !b
        0
      elsif !a
        1
      elsif !b
        -1
      else
        a <=> b
      end
    end
  end

  def sort_by_with_nils_last_with_recursion
    sort do |a, b|
      if block_given?
        a = yield(a)
        b = yield(b)
      end

      sort_by_with_nils_last_with_recursion_one(a, b)
    end
  end

  def sort_by_with_nils_last_with_recursion_one(a, b)
    if !a && !b
      0
    elsif !a
      1
    elsif !b
      -1
    elsif a.is_a?(Array) && b.is_a?(Array)
      max_len = [a.length, b.length].max
      max_len.times do |i|
        a_ = a[i]
        b_ = b[i]
        r = sort_by_with_nils_last_with_recursion_one(a_, b_)
        if r != 0
          return(r)
        end
      end
      0
    else
      a <=> b
    end
  end

  def stable_sort
    self.map.with_index.sort do |(a, i_a), (b, i_b)|
      c = yield(a, b)
      c != 0 ? c : i_a <=> i_b
    end.map(&:first)
  end

  def stable_sort_by
    self.sort_by.with_index {|x, i| [yield(x), i] }
  end

  def first_and_only
    if length == 1
      first
    end
  end

  def first_and_only!
    first_and_only || raise("#first_and_only! expected a single element, got #{length}")
  end

  # from microbm, faster/smaller than map -> uniq, faster/smaller than set
  def uniq_map(&blk)
    uniq(&blk).map(&blk)
  end

  # from microbm, faster/smaller than map -> uniq, faster/smaller than set
  def uniq_length(&blk)
    uniq(&blk).length
  end

  def find_yield(&blk)
    each do |x|
      r = blk.(x)
      return r if r
    end
    nil
  end
end
