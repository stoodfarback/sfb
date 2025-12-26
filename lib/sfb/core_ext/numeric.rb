# frozen_string_literal: true

# active_support/core_ext/numeric/time.rb
# active_support/core_ext/integer/time.rb
# but only these helpers, without pulling in a bunch of other (slower) parts
class Numeric
  def seconds
    ActiveSupport::Duration.seconds(self)
  end
  alias_method(:second, :seconds)

  def minutes
    ActiveSupport::Duration.minutes(self)
  end
  alias_method(:minute, :minutes)

  def hours
    ActiveSupport::Duration.hours(self)
  end
  alias_method(:hour, :hours)

  def days
    ActiveSupport::Duration.days(self)
  end
  alias_method(:day, :days)

  def weeks
    ActiveSupport::Duration.weeks(self)
  end
  alias_method(:week, :weeks)

  def months
    ActiveSupport::Duration.months(self)
  end
  alias_method(:month, :months)

  def years
    ActiveSupport::Duration.years(self)
  end
  alias_method(:year, :years)
end
