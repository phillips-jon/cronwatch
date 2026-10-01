# frozen_string_literal: true

module Cronwatch
  # Warns that a name is deprecated: it still works through 1.x and goes in
  # 2.0. The warning is Ruby's own deprecation category, so it shows where
  # Ruby's deprecation warnings show (`ruby -w`, `-W:deprecated`, or
  # `Warning[:deprecated] = true`) and points at the caller's line.
  #
  # @api private
  module Deprecation
    module_function

    def warn(old, replacement, uplevel: 2)
      Kernel.warn("[cronwatch] #{old} is deprecated and goes in 2.0; use #{replacement}",
                  uplevel: uplevel, category: :deprecated)
    end
  end
end
