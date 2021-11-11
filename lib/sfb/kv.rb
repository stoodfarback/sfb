# frozen_string_literal: true

module Sfb::KV
  @redis_prefix = "Sfb::KV "
  def self.set_redis_prefix(v)
    @redis_prefix = v.to_s.freeze
  end
  def self.redis_prefix
    @redis_prefix
  end

  def self.get(k)
    k = k.to_s
    Sfb::Util.redis_get(redis_prefix + k)
  end

  def self.set(k, v)
    k = k.to_s
    k_full = redis_prefix + k
    Sfb::Util.redis_set(k_full, v)
    v
  end

  def self.delete(k)
    k = k.to_s
    k_full = redis_prefix + k
    exists = Sfb::Util.redis_exists?(k_full)
    v = exists ? Sfb::Util.redis_get(k_full) : nil
    Sfb::Util.redis_delete(k_full)
    v
  end

  def self.fetch(k, &blk)
    k = k.to_s
    k_full = redis_prefix + k
    exists = Sfb::Util.redis_exists?(k_full)
    if exists
      Sfb::Util.redis_get(k_full)
    else
      v = blk.()
      Sfb::Util.redis_set(k_full, v)
      v
    end
  end

  def self.expire(k, seconds)
    k = k.to_s
    k_full = redis_prefix + k
    Sfb::Util.redis_expire(k_full, seconds)
  end

  def self.delete_all_with_prefix(k)
    k = k.to_s
    k_full = redis_prefix + k
    Sfb::Util.redis_delete_all_with_prefix(k_full)
  end

  def self.add_kv_methods(klass)
    prefix = "#{klass.name} "
    method_def_meth = klass.instance_of?(Module) ? :define_singleton_method : :define_method
    klass.send(method_def_meth, :kv_get) do |k|
      Sfb::KV.get(prefix + k)
    end
    klass.send(method_def_meth, :kv_set) do |k, v|
      Sfb::KV.set(prefix + k, v)
    end
    klass.send(method_def_meth, :kv_delete) do |k|
      Sfb::KV.delete(prefix + k)
    end
    klass.send(method_def_meth, :kv_fetch) do |k, &blk|
      Sfb::KV.fetch(prefix + k, &blk)
    end
    klass.send(method_def_meth, :kv_expire) do |k, seconds|
      Sfb::KV.expire(prefix + k, seconds)
    end
    klass.send(method_def_meth, :kv_delete_all_with_prefix) do |k|
      Sfb::KV.delete_all_with_prefix(prefix + k)
    end
    klass.send(method_def_meth, :kv_delete_all) do
      Sfb::KV.delete_all_with_prefix(prefix)
    end
  end
end
