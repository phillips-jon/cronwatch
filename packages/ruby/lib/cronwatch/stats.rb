# frozen_string_literal: true

module Cronwatch
  module Stats
    module_function

    def percentile(values, p)
      return nil if values.empty?

      sorted = values.sort
      index = [sorted.length - 1, [0, ((p / 100.0) * sorted.length).ceil - 1].max].min
      sorted[index]
    end

    def median(values)
      return nil if values.empty?

      sorted = values.sort
      mid = sorted.length / 2
      sorted.length.even? ? (sorted[mid - 1] + sorted[mid]) / 2.0 : sorted[mid]
    end
  end
end
