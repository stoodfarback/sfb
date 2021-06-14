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
        end
      str << str_to_add
    end
    str = str.first(max_len)

    case len
    when Range, Array
      str.first(len.to_a.sample(random: prng))
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
end
