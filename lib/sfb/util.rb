# frozen_string_literal: true

$redis ||= Redis.new

module Sfb::Util
  def self.xxhash64(s)
    XXhash.xxh64(s).to_s(32)
  end

  def self.xxhash64i(s)
    XXhash.xxh64(s)
  end

  def self.activerecord_pg_advisory_xact_lock(key, try: false)
    key_i = activerecord_pg_advisory_xact_lock_key_to_i(key)

    binds = [
      ActiveRecord::Relation::QueryAttribute.new(
        "key", key_i, ActiveModel::Type::BigInteger.new
      ),
    ]

    if try
      sql = "select pg_try_advisory_xact_lock($1)"
      result_raw = ActiveRecord::Base.connection.exec_query(sql, "SQL", binds)
      r = result_raw.first_and_only!["pg_try_advisory_xact_lock"]
      raise("internal error: stoic-resupply-aloha") if r.nil?
      r
    else
      sql = "select pg_advisory_xact_lock($1)"
      ActiveRecord::Base.connection.exec_update(sql, "SQL", binds)
      true
    end
  end

  def self.activerecord_pg_advisory_xact_lock_key_to_i(key)
    key_i = self.xxhash64i(key)
    # pg bigint is 64bits, but signed. xxhash returns unsigned
    key_i_signed = [key_i].pack("Q").unpack1("q")
    key_i_signed
  end

  def self.random
    self.random_string(len: 16)
  end

  # output length is 32 characters by default
  # type can be :base32, :random_letters, :pronounceable
  def self.random_string(prng: SecureRandom, len: nil, type: :base32)
    str = +""
    max_len = len.try(:max) || len.try(:to_i) || 32
    while str.length < max_len
      str_to_add =
        case type
        when :base32
          random_string_some_base32(prng)
        when :random_letters
          random_string_some_random_letters(prng)
        when :pronounceable
          random_string_some_pronounceable(prng, max_len)
        else
          raise(Sfb::Error, "Unknown type: #{type}")
        end
      str << str_to_add
    end
    str = str.first(max_len)

    case len
    when Array
      str.first(len.to_a.sample(random: prng))
    when Range
      str.first(prng.rand(len))
    when Integer
      str.first(len)
    else
      str
    end
  end

  def self.random_string_some_base32(prng)
    num = prng.random_number(2**128)
    Base32::Crockford.encode(num).downcase
  end

  def self.random_string_some_random_letters(prng)
    num = prng.random_number(2**128)
    str = Base32::Crockford.encode(num).downcase
    str.gsub!(/\d/, "")
    str
  end

  def self.random_string_some_pronounceable(prng, max_len)
    alphabet = ("a".."z").to_a
    vowels = %w[a e i o u]
    consonants = alphabet - vowels

    r = []
    (max_len / 3.0).ceil.times do
      r << consonants.sample(random: prng)
      r << vowels.sample(random: prng)
      r << alphabet.sample(random: prng)
    end
    r.join
  end

  def self.http_get(url)
    HTTP.
      headers("User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/81.0.4044.138 Safari/537.36").
      use(:auto_inflate).
      follow(max_hops: 5).
      get(url).
      to_s
  end

  HUMAN_TO_NUMBER_MULTIPLIERS = { "k" => 10**3, "m" => 10**6, "b" => 10**9 }.freeze
  def self.human_to_number(human)
    number = human[/(\d+\.?)+/].to_f
    factor = human.downcase[/[a-z]+$/]
    multiplier = factor.blank? ? 1 : HUMAN_TO_NUMBER_MULTIPLIERS[factor]
    if !multiplier
      raise("couldn't parse human_to_number: #{human.inspect}")
    end

    number * multiplier
  end

  HUMAN_SIZE_TO_NUMBER_MULTIPLIERS = {
    "kb" => 1024**1, "kib" => 1024**1,
    "mb" => 1024**2, "mib" => 1024**2,
    "gb" => 1024**3, "gib" => 1024**3,
    "tb" => 1024**4, "tib" => 1024**4,
  }.freeze
  def self.human_size_to_bytes(human)
    number = human[/(\d+\.?)+/].to_f
    factor = human.downcase[/[a-z]+$/]
    multiplier = factor.blank? ? 1 : HUMAN_SIZE_TO_NUMBER_MULTIPLIERS[factor]
    if !multiplier
      raise("couldn't parse human_size_to_bytes: #{human.inspect}")
    end

    (number * multiplier).round
  end

  def self.str_truncate(str, len = 80)
    str = str.to_s
    if str.length > len
      str = str[0..(len - 4)] + "..."
    end
    str
  end

  def self.noko(html)
    Nokogiri::HTML(html)
  end

  def self.redis_exists?(key)
    $redis.exists?(key)
  end

  def self.redis_get(key)
    if (t = $redis.get(key)).present?
      JSON.parse(t)
    end
  end

  def self.redis_set(key, val, **kwargs)
    $redis.set(key, val.to_json, **kwargs)
    val
  end

  def self.redis_fetch(key, **kwargs, &blk)
    if (r = $redis.get(key)).present?
      return(JSON.parse(r))
    end

    blk.().tap do |r|
      $redis.set(key, r.to_json, **kwargs)
    end
  end

  def self.redis_delete(key)
    $redis.del(key)
  end
end
