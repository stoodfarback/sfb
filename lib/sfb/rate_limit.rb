# frozen_string_literal: true

module Sfb::RateLimit
  Sfb::KV.add_kv_methods(self)

  def self.def_limit(name, delay_seconds_range, chance_double = 0.0)
    name_s = name.to_s
    define_singleton_method(name) do
      ok_at = (kv_get(name_s) || Time.now).to_f
      now = Time.now.to_f
      if now >= ok_at
        chance_double_hit = rand < chance_double
        next_at = chance_double_hit ? now : now + rand(delay_seconds_range)
        kv_set(name_s, next_at)
        true
      else
        false
      end
    end
    define_singleton_method("left_till_#{name}") do
      ok_at = (kv_get(name_s) || Time.now).to_f
      now = Time.now.to_f
      (ok_at - now).round(2)
    end
    define_singleton_method("set_#{name}") do |val|
      next_at = Time.now.to_f + val
      kv_set(name_s, next_at.to_f)
    end
  end

  def self.sleep_till_next(*names, quiet: false)
    parts = names.map { send("left_till_#{it}") }
    to_sleep = parts.min
    if to_sleep < 0
      to_sleep = 0
    end
    to_sleep += 0.01
    to_sleep = to_sleep.round(2)
    quiet or puts("RateLimit sleep_till_next #{to_sleep}")
    sleep(to_sleep)
  end
end
