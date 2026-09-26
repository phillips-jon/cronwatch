# frozen_string_literal: true

begin
  require "rack"
rescue LoadError
  raise LoadError, "cronwatch/web needs the rack gem: add `gem \"rack\"` to your Gemfile (Rails apps already have it)"
end

require "cronwatch"
require_relative "web/html"
require_relative "web/app"
