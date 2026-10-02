# Changelog

All notable changes to the CronWatch module for Drupal, newest first. Each release carries the CronWatch library (`cronwatch/cronwatch`) of the same version.

## 0.12.0 - 2026-10-01

### Added
- Released with the library 0.12.0, which adds the `under_floor` alert: a job that runs cleanly but reports a metric below its `floor`, or at 0 after runs that never were, sends one warning. Jobs take a `floor` option beside `budget`.

## 0.11.1 - 2026-10-01

### Changed
- Released with the library 0.11.1, whose own dashboard gains a light and dark switch (Cmd+Shift+D); the dashboard in Drupal's admin pages is unchanged and follows the system's setting.

## 0.11.0 - 2026-10-01

### Added
- Ultimate Cron: each run of its jobs is recorded, `drupal:<module>` for a module's `hook_cron` and `drupal:job:<id>` for any other (triggers `ultimate-cron` and `ultimate-cron-manual`), each job on its own rules, read as Ultimate Cron reads them, and every cron run is still `drupal:cron`. Before, CronWatch left a site running Ultimate Cron alone.
- From the library: the JSON API's root answers what is serving it: the library, its language and version, and the API's version (`api: 1`).

### Changed
- Runs are recorded with the triggers `drupal-cron` and `drupal-queue`, the integration's name as every other integration spells it; runs recorded before keep `cron` and `queue`.
- From the library: the JSON API's silence and unsilence answer the job's summary, `{ ok: true, job }`, instead of its stored state.
- From the library: the webhook's body starts with `"schema": 1`, the payload's version; its JSON Schema is at https://cronwatch.dev/schemas/webhook/1.json.
- From the library: a blank `CRONWATCH_ENV` or `APP_ENV` counts as unset.
- From the library: a run id longer than 200 characters is refused, on every path.

### Fixed
- From the library: a job's stored state keeps the fields a newer release wrote, so sites and apps on different 1.x releases can share one database.
- From the library: one malformed job, run or state row (a hand edit, a damaged database) affects only its own job instead of stopping every check or the whole dashboard, and a state row that is not JSON is replaced by the next write.
- From the library: the JSON API takes only a `Bearer` Authorization header as its token, so a proxy's Basic auth in front of the site no longer locks it.
- From the library: without ext-curl, an alert channel's request keeps its 10 second deadline and its 1 MiB cap while the server keeps sending.
- The dashboard in the admin pages ignores an `Authorization` header, so a user who may only view it can no longer run the check with a GET of `/api/check` and any bearer token. Running the check there needs "administer cronwatch", whatever the path.
- A check through `/cronwatch/api/check` by GET with the token or `CRON_SECRET` (a platform cron), or by the dashboard's `/api/check` or `/check/` in the admin pages, declares every job first, as a POST to `/check` did. Before, such a check left a removed module's job on its old schedule.

## 0.10.0 - 2026-09-30

### Changed
- `composer.json` points its documentation link at the Drupal page of the docs, not the docs' front page.

### Added
- `$settings['cronwatch_base_url']`, the site's address for the links in alerts.

### Fixed
- From the library: an alert is saved in the same write that records the failure, so a process killed before the alert went out no longer loses it; output is redacted before it is shortened; webhook URLs and keys are kept out of the stack traces of failed alert sends.
- A `description` given in a queue worker's `#[Cronwatch\Watch]` is now shown, instead of being replaced by the module's default ("Items of the ... queue").
- One job with options the library refuses (from `hook_cronwatch_job_options_alter()`, a worker's `#[Cronwatch\Watch]` or an imported schedule) no longer stops every check: it is reported and declared with fewer options, and its runs are still recorded.
- A module with two `hook_cron` methods (Drupal 11.1 and newer) is one run per cron run, failed if either threw, instead of a failure and a recovery each time.
- `POST /cronwatch/api/check` declares the jobs only once the token is checked.
- Alert links no longer take their host from a visitor's request on a site without `trusted_host_patterns`; they use `$settings['cronwatch_base_url']`, or go without a link.

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
- When cron's schedule comes from Automated Cron, its interval reads in the largest units that fit (`every 3h`, not `every 10800s`).
- On the dashboard, long job names wrap at their separators (such as `:` and `/`) instead of running off the page.

## 0.6.0 - 2026-09-28

### Added
- First release. Every cron run is recorded in the site's own database as `drupal:cron`, and each module's `hook_cron` in it as `drupal:<module>`; queue workers you choose, or mark with `#[Cronwatch\Watch]`, are watched too, each item a run.
- Alerts when cron is missed, and when a `hook_cron` or queue item fails, gets stuck or runs much slower than usual, and again when it recovers, by email through the site's mail system, Slack or a webhook, set at Configuration, System, CronWatch.
- The check that finds missed and stuck runs, after every cron run and from `drush cronwatch:check`.
- The dashboard at Reports, CronWatch: the jobs' health, the last day as a timeline, each job's runs and output.
- The JSON API for `@cronwatch/mcp`, off until a token is set in `settings.php`.
- `hook_cronwatch_alerts_alter()` and `hook_cronwatch_job_options_alter()`.
