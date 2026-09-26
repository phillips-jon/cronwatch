# frozen_string_literal: true

# The dashboard and JSON API, as a Rack app. Needs the rack gem; the Rails
# integration loads this file itself.
#
#   require "cronwatch/web"
#   run Cronwatch::Web.new(CW)
begin
  require "rack"
rescue LoadError => e
  raise LoadError, "cronwatch/web needs the rack gem: add `gem \"rack\"` to your Gemfile " \
                   "(Rails apps already have it) (#{e.message})"
end

require "cronwatch" unless defined?(Cronwatch::Client)
require_relative "web/html"
require_relative "web/app"
