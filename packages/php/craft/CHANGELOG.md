# Release Notes for CronWatch

## Unreleased

### Added
- The plugin has its own icon, in Settings, Plugins and in the Control Panel's navigation.

### Changed
- The settings page shows `config/cronwatch.php` and `php craft cronwatch/check` as code.
- The plugin's documentation link goes to the Craft CMS page of the docs, not the docs' front page.

### Fixed
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
