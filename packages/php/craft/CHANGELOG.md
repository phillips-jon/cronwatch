# Release Notes for CronWatch

## Unreleased

### Added
- The settings offer every alert channel, not only email, Slack and the webhook: Discord, email through Resend, Postmark, SendGrid, Mailgun or Amazon SES, text messages through Twilio, and Sentry, Honeybadger, Datadog, Rollbar, Bugsnag and New Relic. Each sends once its required fields are set (`discordWebhookUrl`, `resendApiKey` and the rest, each taking an environment variable), and a channel only partly filled in is refused beside the field it lacks.
- "Send a test alert" on the settings page sends one alert to every channel the saved settings name and shows what each answered.

## 0.12.0 - 2026-10-01

### Added
- Released with the library 0.12.0, which adds the `under_floor` alert: a job that runs cleanly but reports a metric below its `floor`, or at 0 after runs that never were, sends one warning. Jobs take a `floor` option beside `budget`.

## 0.11.1 - 2026-10-01

### Changed
- Released with the library 0.11.1, whose own dashboard gains a light and dark switch (Cmd+Shift+D); the dashboard in the control panel is unchanged and follows the system's setting.

## 0.11.0 - 2026-10-01

### Added
- From the library: `GET /cronwatch/api` answers what is serving it: the library, its language and version, and the API's version (`api: 1`).

### Changed
- Runs are recorded with the triggers `craft-queue` and `craft-command`, the integration's name as every other integration spells it; runs recorded before keep `queue` and `command`.
- From the library: the JSON API's silence and unsilence answer the job's summary, `{ ok: true, job }`, instead of its stored state.
- From the library: the webhook's body starts with `"schema": 1`, the payload's version; its JSON Schema is at https://cronwatch.dev/schemas/webhook/1.json.
- From the library: a blank `CRONWATCH_ENV` or `APP_ENV` counts as unset.
- From the library: a run id longer than 200 characters is refused, on every path.

### Fixed
- `GET /cronwatch/api`, with no path after it, reaches the JSON API instead of the site's 404 page, so the API's own answer at its root (the library and its version, from 1.0) is served.
- From the library: a job's stored state keeps the fields a newer release wrote, so sites and apps on different 1.x releases can share one database.
- From the library: one malformed job, run or state row (a hand edit, a damaged database) affects only its own job instead of stopping every check or the whole dashboard, and a state row that is not JSON is replaced by the next write.
- From the library: the JSON API takes only a `Bearer` Authorization header as its token, so a proxy's Basic auth in front of the site no longer locks it.
- From the library: without ext-curl, an alert channel's request keeps its 10 second deadline and its 1 MiB cap while the server keeps sending.
- The dashboard in the Control Panel ignores an `Authorization` header, so a user who may only view it can no longer run the check with a GET of `/api/check` and any bearer token. Running the check there needs the `cronwatch-manage` permission, whatever the path.
- A watched queue job that another plugin cancels before it runs (marking `EVENT_BEFORE_EXEC` handled, after CronWatch's listener) is no run at all. Before, its run was left running, or recorded failed as interrupted when the worker's process for it ended.
- A check through `/cronwatch/api/check` by GET with the token or `CRON_SECRET` (a platform cron), or by the dashboard's `/api/check` or `/check/` in the Control Panel, declares the settings' jobs first, as a POST did. Before, such a check left a command taken out of the settings on its old schedule, and never declared a new one.

## 0.10.0 - 2026-09-30

### Added
- Listed in the Craft Plugin Store.
- The plugin has its own icon, in Settings, Plugins and in the Control Panel's navigation.

### Changed
- The settings page shows `config/cronwatch.php` and `php craft cronwatch/check` as code.
- The plugin's documentation link goes to the Craft CMS page of the docs, not the docs' front page.

### Fixed
- From the library: an alert is saved in the same write that records the failure, so a process killed before the alert went out no longer loses it; output is redacted before it is shortened; webhook URLs and keys are kept out of the stack traces of failed alert sends.
- A watched command run by another that catches its exception is recorded as failed, and its caller finishes, instead of both being left running and later reported stuck.
- `POST /cronwatch/api/check` declares the jobs only once the token is checked, so a caller without it gets 401, not the site's error page when the store is down.
- An alert sent from a web request no longer takes its link's host from the request's `Host` header where `@web` is not configured; it uses the primary site's URL, or goes without a link.
- A `description` given to a command or queue job (in `config/cronwatch.php`, on the `WatchCommand` behavior or in `#[Cronwatch\Watch]`) is now shown, instead of being replaced by the plugin's default.

## 0.9.0 - 2026-09-30

### Fixed
- On Postgres, a run whose trigger or metric names hold a NUL character is stored without it, instead of being lost.

## 0.8.0 - 2026-09-29

### Changed
- Updated to the library's 0.8.0.

## 0.7.0 - 2026-09-29

### Changed
- A grace or other duration longer than 64 characters is refused rather than read.

## 0.6.1 - 2026-09-28

### Changed
- On the dashboard, long job names wrap at their separators (such as `:` and `/`) instead of running off the page.

## 0.6.0 - 2026-09-28

### Added
- First release. Console commands the crontab runs and queue jobs you list in `config/cronwatch.php` (or mark with the `WatchCommand` behavior or `#[Cronwatch\Watch]`) are recorded in the site's own database.
- Alerts when a run is missed, fails, gets stuck or runs much slower than usual, and again when it recovers, by email through Craft's mailer, Slack or a webhook, set under Settings, Plugins, CronWatch.
- `php craft cronwatch/check`, the check that finds missed and stuck runs, to run from the crontab.
- CronWatch in the Control Panel: the jobs' health, the last day as a timeline, each job's runs and output.
- The JSON API for `@cronwatch/mcp`, off until a token is set.
