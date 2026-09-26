# frozen_string_literal: true

# The ActiveRecord store. Needs the activerecord gem.
#
#   require "cronwatch/active_record"
#   CW = Cronwatch.new(store: Cronwatch::Stores::ActiveRecord.new)
#
# `require "cronwatch/rails"` loads it on first use, so a Rails app does not
# need this line.
require "cronwatch"
require_relative "stores/active_record"
