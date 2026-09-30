# Changelog

All notable changes to the CronWatch module for Drupal, newest first. Each release carries the CronWatch library (`cronwatch/cronwatch`) of the same version.

## Unreleased

### Changed
- `composer.json` points its documentation link at the Drupal page of the docs, not the docs' front page.

### Fixed
- A `description` given in a queue worker's `#[Cronwatch\Watch]` is now shown, instead of being replaced by the module's default ("Items of the ... queue").

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
