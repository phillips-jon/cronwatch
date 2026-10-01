# frozen_string_literal: true

# Serves Cronwatch::Web over HTTP for packages/mcp/test/ruby-web.test.ts, which
# drives @cronwatch/mcp against it. Seeded like the MCP tests' own end to end
# case: a "nightly" job with one good run and one failed one, and a fixed clock.
# Mounted under /cronwatch with Rack::URLMap, the way Rails' `mount` passes
# the mount point, so the app reads it from SCRIPT_NAME.
#
#   ruby packages/ruby/test/web/server.rb PORT
#
# Needs rack plus a server that rackup can start (puma, or webrick). Alerts
# are printed as "alert <job> <type>" lines.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "cronwatch/web"

port = Integer(ARGV.fetch(0))
now = Time.utc(2026, 1, 5, 2).to_i * 1000
$stdout.sync = true

channel = Cronwatch::Alerts::Custom.new("test") { |alert| puts "alert #{alert.job} #{alert.type}" }
cw = Cronwatch.new(store: Cronwatch::Stores::Memory.new, alerts: [channel], cron_secret: nil, now: -> { now })
nightly = cw.job("nightly", schedule: "0 2 * * *", timezone: "UTC", grace: "15m")
nightly.run { |job| job.log("step 1") }
now += 60_000
begin
  nightly.run do |job|
    job.log("step 2")
    raise "db down"
  end
rescue RuntimeError
  nil
end

app = Rack::URLMap.new("/cronwatch" => cw.routes(token: "tok"))

handler =
  begin
    require "rackup"
    Rackup::Handler.pick(%w[puma webrick])
  rescue LoadError
    require "rack/handler"
    Rack::Handler.pick(%w[puma webrick])
  end
puts "serving on #{port} with #{handler.name}"
handler.run(app, Host: "127.0.0.1", Port: port, Silent: true)
