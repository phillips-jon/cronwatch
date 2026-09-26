# cronwatch

Cron and scheduled-job monitoring that lives inside your Ruby app. Wrap a job, run a check, and get told when it is missed, failed, stuck, slow or over budget. No server to run.

This is the Ruby port of [`@cronwatch/sdk`](https://cronwatch.dev): the same rules, the same alert text, and the same stored rows, so a Node process and a Ruby process can share one database. Ruby 3.2 or newer; the only dependency is `fugit`.

```ruby
require "cronwatch"

CW = Cronwatch.new(
  alerts: [Cronwatch::Alerts::Slack.new(webhook_url: ENV.fetch("SLACK_WEBHOOK_URL"))],
)

NIGHTLY = CW.job("nightly-report", schedule: "0 2 * * *", timezone: "UTC", grace: "15m", expect: "Report written")

NIGHTLY.run do |job|
  job.log("Report written:", path)
  job.metric(:cost, 1.2)
end

CW.start # checks for missed and stuck runs every minute, in a background thread
```

Channels: `Cronwatch::Alerts::Slack`, `Discord`, `Webhook` (signed with `X-CronWatch-Signature`), `Console` (the default) and `Custom`. The default store keeps everything in memory.

Documentation: [cronwatch.dev/docs](https://cronwatch.dev/docs/). The design of the port is in [DESIGN.md](DESIGN.md).

## Development

```sh
bundle install
bundle exec rake test
```

The tests replay the cases in `conformance/` at the repository root, which `npm run conformance` generates from the TypeScript SDK. When the two disagree, the Ruby side is wrong.
