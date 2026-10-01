# Changelog

All notable changes to the CronWatch module for Drupal, newest first. Each release carries the CronWatch library (`cronwatch/cronwatch`) of the same version.

## Unreleased

### Added
- From the library: the JSON API's root answers what is serving it: the library, its language and version, and the API's version (`api: 1`).

### Changed
- Runs are recorded with the triggers `drupal-cron` and `drupal-queue`, the integration's name as every other integration spells it; runs recorded before keep `cron` and `queue`.
- From the library: the JSON API's silence and unsilence answer the job's summary, `{ ok: true, job }`, instead of its stored state.
- From the library: the webhook's body starts with `"schema": 1`, the payload's version; its JSON Schema is at https://cronwatch.dev/schemas/webhook/1.json.
- From the library: a blank `CRONWATCH_ENV` or `APP_ENV` counts as unset.
- From the library: a run id longer than 200 characters is refused, on every path.

### Fixed
- From the library: a job's stored state keeps the fields a newer release wrote, so sites and apps on different 1.x releases can share one database.

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
