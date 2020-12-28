# frozen_string_literal: true

class String
  def lstrip_utf8
    sub(/\A[[:space:]\u200b]+/, "")
  end

  def rstrip_utf8
    sub(/[[:space:]\u200b]+\z/, "")
  end

  def strip_utf8
    lstrip_utf8.rstrip_utf8
  end

  def lstrip_utf8!
    sub!(/\A[[:space:]\u200b]+/, "")
  end

  def rstrip_utf8!
    sub!(/[[:space:]\u200b]+\z/, "")
  end

  def strip_utf8!
    lstrip_utf8!
    rstrip_utf8!
    self
  end
end
