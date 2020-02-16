require("yaml/store")

class Sfb::Store
  # a wrapper for YAML::Store with implicit transactions and caching

  def initialize(file_path)
    @store = YAML::Store.new(file_path, thread_safe = true)
    @store.ultra_safe = true
    @cache = {}
  end

  def [](k)
    if @cache.key?(k)
      @cache[k]
    else
      v = nil
      @store.transaction(read_only = true) do
        v = @store[k]
      end
      @cache[k] = v
    end
  end

  def []=(k, v)
    @store.transaction do
      @store[k] = v
      @cache.delete(k)
    end
  end
end
