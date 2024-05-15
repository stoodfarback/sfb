# frozen_string_literal: true

class Sfb::Store
  # a wrapper for YAML::Store with implicit transactions and caching

  def initialize(file_path)
    require("yaml/store")
    @store = YAML::Store.new(file_path, thread_safe = true)
    @store.ultra_safe = true
    @cache = {}
  end

  def transaction(read_only: false)
    @store.transaction(read_only) do
      yield
    end
  end

  def [](k)
    if @cache.key?(k)
      @cache[k]
    else
      v = nil
      transaction(read_only: true) do
        v = @store[k]
      end
      @cache[k] = v
    end
  end

  def []=(k, v)
    transaction do
      @store[k] = v
      @cache.delete(k)
    end
  end

  def key?(k)
    r = @cache.key?(k)
    return(r) if r
    transaction(read_only: true) do
      @store.root?(k)
    end
  end

  def get_or_set(k, &)
    if key?(k)
      self[k]
    else
      self[k] = yield
    end
  end
end
