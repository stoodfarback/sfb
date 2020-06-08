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
end
