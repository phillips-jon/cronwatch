# The PHP port

`packages/php` is `cronwatch/cronwatch` on Packagist (namespace `Cronwatch\`): the same library as `@cronwatch/sdk`, for PHP apps, from a plain crontab script to Laravel, Symfony, WordPress, Drupal and Craft. It is a port, not a new design, made the way the Ruby gem and the Python package were (see their `DESIGN.md`). The TypeScript SDK is the source of truth for every behaviour, message and stored byte; when the two disagree, the PHP side is wrong.

## Rules

- PHP 8.2 or newer, tested on 8.2 and 8.5 in CI (and 8.3 by hand). 8.1 left security support at the end of 2025, and 8.2 is the floor of everything the later phases plug into: Laravel 11 and 12, Symfony 7, Craft 5 and PHPUnit 11 all require it, and Drupal 11 requires 8.3. WordPress still runs on older PHP, but a plugin declares `Requires PHP: 8.2` and WordPress refuses to activate it on anything older, with a message, rather than failing at runtime. The code itself leans on 8.1 (readonly properties, `never`, first-class callables, `array_is_list`); nothing here would be simpler on 8.3, so the floor is set by support and by the frameworks, not by syntax.
- The core has no runtime dependencies beyond `ext-json` and `ext-pcre`, which every PHP has. Cron parsing and fire times are a port of croner 10 (`src/Cron/`, as the Python port's `_cron.py`), zones come from PHP's own zone database, and no `mbstring` or `intl` is needed: UTF-16 lengths, cuts and scrubbing are done on the bytes. The stores need `pdo_sqlite` or `pdo_mysql`, named in `suggest` and checked with a clear `LogicException` when missing. Later phases keep to this: an optional piece is its own class, and needs only what it uses.
- Times are epoch milliseconds (`int`) everywhere, as in the SDK, so `Evaluate` ports line for line and stored rows are identical. PHP's `int` is 64 bits, so no time loses precision.
- Names are the SDK's, since PHP is camelCase too: `failuresBeforeAlert`, `maxDuration`, `startedAt`, `recordRun()`, `jobsWithRuns()`. Job options are an array with the SDK's keys, in the order given (`['schedule' => '0 2 * * *', 'grace' => '15m']`), so the stored definition has the SDK's key order; an unknown key is refused. The client takes named arguments (`new Cronwatch(store: ..., alerts: ...)`). Run statuses, conditions, alert types and health are the wire strings, with constants for them (`RunStatus::OK`, `Condition::OVER_BUDGET`, `JobHealth::NEVER_RAN`); PHP enums were weighed and left out, since every value that crosses a store or a network is a string and a newer writer's value must pass through unharmed.
- JSON is written by `Js::stringify`, which is `JSON.stringify` byte for byte: numbers as JavaScript prints them (`2` not `2.0`, `1e-7`, `1e+21`), array-index keys first in ascending order and the rest as inserted, only control characters, quotes and backslashes escaped (so `/`, `é` and U+2028 are written as themselves). A PHP array that is a list is a JSON array, anything else an object; the types write their maps (metrics, open conditions, details, budgets) as objects, so an empty one is `{}`. `json_encode` differs from `JSON.stringify` on each of these points, and is used nowhere a byte counts.
- Alert titles and messages are the SDK's text, character for character. `JobDefinition` keeps its fields as given, in order (defaults, then options as given, then `name`, and a stored `expect` last), including fields a newer writer added.
- Text entering a run (logged output, a returned string, an error's message) is made valid UTF-8 first: bytes that are not UTF-8 become U+FFFD, one per maximal subpart, as a JavaScript string decoded from them holds it. Lengths and cuts are in UTF-16 code units, as JavaScript counts them (`Js::length16`, `head16`, `tail16`); a cut through a surrogate pair leaves U+FFFD where JavaScript keeps a lone surrogate, which is what that surrogate becomes once written out as UTF-8, so the stored bytes are the same.
- Secret redaction uses the SDK's patterns in PCRE's UTF mode. PHP's `/u` also turns on Unicode `\s`, `\b` and case folding, so JavaScript's whitespace class is spelled out, `\b` is spelled with ASCII word characters, and case-insensitive words are spelled `[Ss][Ee]...` (ASCII-only folding, as JavaScript's `/i` has it here). Text with characters outside the Basic Multilingual Plane is matched with each one written as two placeholder characters, one per UTF-16 surrogate, so bounded quantifiers count as JavaScript counts, then put back together. The PEM pattern's body (`(?:...|-(?!----)){0,16384}`) is measured in code rather than by PCRE, which writes a bounded group out once per repeat and cannot compile sixteen thousand copies; the result is the same, since the footer is optional and JavaScript never backtracks into the body. `conformance/output.json`'s 204 redaction cases pass.
- Every condition opens once and closes with a recovery. No repeat alerts. A job whose schedule is removed while missed is open has missed closed by the next check with a recovery of its own (`reason: "unscheduled"`).
- A job's function may throw anything (`Exception` or `Error`): it is recorded as the failure and thrown again. A run still in progress when its process ends (`exit()` inside the job, or a fatal error such as memory running out, which no `catch` sees) is recorded by the client's shutdown hook as a failed run, `Interrupted: the process exited during the run` or `Interrupted: Fatal error: <message>` with the file and line, so no run is left running to be reported stuck later. A process killed outright (SIGKILL, the OOM killer) records nothing, and its run is marked stuck after the job's timeout, as in every port.
- An error is written `Name: message` and up to five frames, innermost first, each `    at Class->method (file:line)`, as a JavaScript stack reads. The name is the class's own name without its namespace (`PDOException`, `ImportFailed`), as a JavaScript error's name has none.
- The environment is read in one place, `Env`: the first of `CRONWATCH_ENV`, `APP_ENV` (Laravel, Symfony, Craft) and `WP_ENVIRONMENT_TYPE` (WordPress) that is set, from `getenv()`, `$_ENV` or `$_SERVER`, since frameworks that read a `.env` file put its values in one of those. It only decides whether the in-memory store warns that it forgets.
- No em or en dashes anywhere, as in the rest of the repo.

## Layout

```
packages/php/
  composer.json  phpunit.xml.dist  README.md  LICENSE  DESIGN.md
  src/
    Cronwatch.php         the client: job, run, check, silence, forget, jobs, runs, recordRun, resumeRun, VERSION
    Js.php                JavaScript's numbers, JSON.stringify, trim, \s, UTF-16 lengths, UTF-8 scrubbing, Date.UTC, toISOString
    Env.php               the environment
    Duration.php          "15m", "1h30m", DateInterval: parse and format
    Stats.php             percentiles
    Output.php            the output cap, error messages, secret redaction
    Schedule.php          parse, nextFire, expectation, runCovers, firesBetween (schedule.ts)
    ParsedSchedule.php  Expectation.php
    Cron/                 croner: CronPattern (the reading of an expression, its checks and messages), CronDate (the walk),
                          Cron (nextRuns), Zone (zones, croner's wall-clock arithmetic, fromTZ), CronError
    Evaluate.php          the alert rules, pure functions (evaluate.ts)
    Evaluation.php  CheckEvaluation.php
    Format.php            alert titles and messages
    Serialize.php         stored definitions, expect rules
    Pattern.php           a regular expression for expect, stored as "/source/flags"
    Run.php  JobState.php  JobDefinition.php  StoredJob.php  Alert.php  AlertDraft.php  JobSummary.php  CheckResult.php
    JobWithRuns.php  RunStatus.php  Condition.php  AlertType.php  JobHealth.php  TriageContext.php  Source.php
    Job/                  JobHandle (run, wrap, start, resume), JobContext (log, metric, aborted), RunRecorder,
                          RunHandle (a run started by start() or found by resume()), AbortSignal, AbortError, RetryFinish
    Alerts/               AlertChannel (the interface), ChannelContext, Console, Custom
    Store/                Store (the interface), UpdatesRunIf and ComparesAndSetsState (the conditional writes),
                          MemoryStore, Sql (schema, statements, parameters, rows), PdoStore, SqliteStore, MysqlStore
  tests/
    ConformanceTest.php       replays conformance/*.json that the core covers, the store scripts against every store
    ClientTest.php  ClientHardeningTest.php  StartFinishTest.php  CorrectnessTest.php  ConcurrencyTest.php
                              the SDK's client tests
    StoreConformanceTest.php  store-conformance.ts, for memory, SQLite (in memory and on disk), MySQL and MariaDB
    FinishOnceTest.php        finish-once and concurrency with real processes (tests/workers/worker.php) on SQLite,
                              MySQL and MariaDB
    SqliteStoreTest.php  MysqlStoreTest.php  JsTest.php
    ShutdownTest.php          a run ended by exit() or a fatal error is recorded (tests/workers/interrupted.php)
    NodeCompatTest.php        one SQLite file shared with the built SDK (tests/node/node_store.mjs)
    ScheduleFuzzTest.php      generated expressions answered by croner itself (tests/node/schedule_fuzz.mjs)
    Support/                  the test clock, a capturing channel, stores that fail or interleave on cue, backends
```

## The PHP API

```php
use Cronwatch\Cronwatch;
use Cronwatch\Job\JobContext;
use Cronwatch\Store\SqliteStore;

$cw = new Cronwatch(
    store: new SqliteStore('/var/lib/app/cronwatch.db'),   // default: a MemoryStore
    alerts: [fn (Cronwatch\Alert $alert) => page($alert->title, $alert->message)],   // default: Console
    retention: '30d',
);

$nightly = $cw->job('nightly-report', [
    'schedule' => '0 2 * * *', 'timezone' => 'UTC', 'grace' => '15m', 'timeout' => '30m',
    'expect' => 'Report written', 'budget' => ['cost' => 2], 'failuresBeforeAlert' => 1,
]);

$nightly->run(function (JobContext $job) {
    $job->log('Report written:', $path);
    $job->metric('cost', 1.2);
});

$task = $nightly->wrap($callable);   // a callable whose every call is a run; Cronwatch::current() is its context
$cw->check();                        // from a crontab line, or the framework's scheduler, every few minutes
$cw->silence('nightly-report', '2h');
```

`run()` returns what the function returns and throws what it throws, after the run is recorded; a returned string is the output when nothing was logged. `$cw->run($name, $fn, $options)` declares and runs. Durations are strings, milliseconds or a `DateInterval` (stored as its milliseconds). `expect` is a string the output must contain, a `Pattern` (`new Pattern('/wrote \d+ files/i')`) it must match, or a callable; a plain string is always a substring, since PHP has no regular expression type to tell the two apart. `defaults:` takes grace, timeout, timezone and failuresBeforeAlert. `cronSecret:` is the check endpoint's secret for the web phase: null (the default) reads `CRON_SECRET`, `""` counts as unset, and `false` lets the endpoint run without one, where the SDK's options take `null` for that (PHP's null is its default).

## Runs that span calls

`$job->start(trigger:, id:)`, `$job->resume($id)` and `$cw->resumeRun($name, $id)` are the SDK's `start()`, `resume()` and `resumeRun()`, and return a `RunHandle`: `id`, `job`, `startedAt`, `isActive()`, `log()`, `metric()`, `metrics()`, `flush()`, `finish($outcome = null)` and `fail($error)`. An outcome is null or `['status' => 'ok']` (ok), `['error' => $e]` or a `Throwable` on its own (failed, written like an error `run()` caught), or a string or `['result' => $x]`, treated like `run()`'s return value. The SDK's other outcome, a `Response` of 400 or more failing the run, waits for the web phase.

The client's side follows `client.ts`: a start with an id checks it (the SDK's messages, including the reserved `pgcron:` prefix) and finds a run already stored under it, so two starts with one id record one run and another job's start with that id throws. `finish()` reads the stored run again, joins the stored output with the handle's (capped) and merges metrics (the handle's win), then judges it with the same code as `run()`. `flush()` redacts the lines it appends and writes only over a row still running and of this job (`updateRunIf`); when it cannot, the handle keeps the lines for `finish()`, and it keeps the first 16 KB of what it flushed so `expect` at finish sees an early line. The store never throws out of `start`, `resume`, `flush` or `finish`: failures go to `onError` as `recording <job>`, `starting <job>`, `resuming <job>`, `flushing <job>` or `finishing <job>`. A store that fails during `finish()` records nothing and leaves the handle active, lines kept, so it can be called again. A finish that records nothing (`... was already finished by this handle`, `... was already finished as ok`, `... was not found`, `... belongs to job "<other>"`) is reported, never thrown, and returns null.

A run is judged once, however many processes finish it: the finish is written only over a stored row still `running`, else over one still `timeout` (a check already counted it as stuck: a late failure is written but not judged, a late success is judged and recovers), through the store's `updateRunIf`, one conditional `UPDATE`. Only the process whose write lands evaluates. The stuck check marks a run timed out the same way, so a finish that landed meanwhile wins. `insertRun` throws for an id already stored, the memory store included. `FinishOnceTest` holds this with real processes: two finishing one run, two recording one run from a source, six starting and finishing the same five ids, and three failing one job at once, on SQLite, MySQL and MariaDB.

## One thing at a time

A PHP process runs one thing at a time, and usually lives for one request or one cron script, so the client has no threads, locks or interval timer. A job runs in the caller. Every read-modify-write of a job's state goes through `updateState`: it reads the state, works out the next one, and writes it only when it changed, with `version` one higher, through the store's `compareAndSetState` against the version read; a refused write is worked out again from a fresh read, up to 10 times. A store without `compareAndSetState` gets `setState`. This is what keeps processes sharing a store (PHP-FPM workers, queue workers, cron scripts) from losing each other's updates, and `ConcurrencyTest` makes the moment on purpose in one process while `FinishOnceTest` does it with several.

There is no `start()`: a PHP process does not stay up between checks unless it is a worker, so `check()` is called from a crontab line, the framework's scheduler, or a worker's loop. The later phases give each framework its way of doing that (see Frameworks). A check called from inside a check (a channel, a source or triage calling `check()`) throws `LogicException`, where the SDK would wait on the check it is part of.

## Delivery

`deliver: 'now'` (the default) sends each alert from the process that produced it. `deliver: 'check'` sends nothing: the alert is queued in the job's state (`undelivered`, at most 20, the oldest dropped first and reported) for the next check in a process that delivers now, which triages and sends it, as the SDK's `deliver: "check"` does. An alert no channel accepted is queued the same way and retried once per check, oldest first; one that no longer describes the job (`Evaluate::staleAlert`) is dropped; one check spends at most 20 seconds of wall clock retrying across all jobs. Triage is tried once per alert: `Alert::$triage` null with `triageTried` true is JSON `null`, never tried again.

Channels are sent to one after another, and triage is asked in turn, since PHP cannot run them at once or abandon one that hangs. Each gets its deadline instead: triage is handed an `AbortSignal` that aborts after 25 seconds (`remainingMs()` for the request's own timeout), and the channels of the next phase set a ten second deadline on their requests, as the SDK's `fetch` has. A diagnosis that arrives late is used rather than thrown away.

## Channels

A channel implements `Alerts\AlertChannel` (`name()` and `send(Alert, ChannelContext)`, which throws when the alert went nowhere), or is any callable, which becomes a `Custom` channel named "custom"; one that takes two arguments also gets the `ChannelContext`, whose `onError()` reports a problem that did not stop the alert as `alert channel <name>`. Phase 1 has `Console` (the default: standard error on the command line, PHP's error log elsewhere) and `Custom`. The SDK's channels (Slack, Discord, webhook, Resend, Postmark, SendGrid, Mailgun, SES, Twilio, Sentry, Honeybadger, Datadog, Rollbar, Bugsnag, New Relic) come in phase 2, request for request as the gem's and the Python package's are, replaying `conformance/channels.json`.

## Sources

`sources:` takes objects implementing `Source` (`name()` and `sync(Cronwatch $host)`), as the SDK's `sources` does. `check()` calls each, in order, after the store is ready and before anything else; one that throws is reported as `source <name>` and the check carries on, and the alerts a sync returns are added to the check's result. The host is the client: `job()`, `recordRun()`, `$store`, `now()` and `onError()`. `recordRun($run, evaluate: true)` is the SDK's `recordRun`, claim and all. The pg_cron source is phase 2.

## Keeping in step

`conformance/` at the repo root holds JSON cases generated from the TypeScript build by `scripts/conformance.mjs`. `ConformanceTest` replays every case the core covers (duration, schedule, evaluate, format, health, output, and the store scripts against the memory, SQLite, MySQL and MariaDB stores), comparing values as the JSON the SDK writes, and fails on a fixture file it neither replays nor places in a later phase (channels, pg_cron and triage). A behaviour change lands in TypeScript first, `npm run conformance` regenerates the fixtures, and this package is fixed until they pass. The fixtures needed nothing new for PHP.

Croner parity is also checked against croner itself: `ScheduleFuzzTest` generates 3,000 expressions (valid and malformed, nicknames, names, ranges, steps, lists, `L`, `W`, `LW`, `#`, `?`, `+`, six fields) in zones with and without daylight saving, from times around the clock changes, and the SDK in Node must give the same error message or the same fire times. `NodeCompatTest` has the built SDK and `SqliteStore` replay the same store calls into two files and compares what each reads of the other's and every column's bytes and SQLite type, and has a Node client and a PHP client take turns on one file and on one job's state version. Both need Node and the built SDK, and are skipped without them.

## Storage

`MemoryStore` keeps everything in the process, cloned through JSON as the SDK's is. A PHP process usually ends with its request or its script, so it is for tests and trying things out; the client warns when it is the default in production.

`SqliteStore($path, pdo:, prefix:)` writes the same three tables as `packages/sdk/src/stores/sql.ts`: the same names (`cronwatch_` prefix by default, the same prefix rules), the same `CREATE` text (so `sqlite_master` reads the same whoever created them), the same statements, parameters bound with their types, and the same JSON in the JSON columns. WAL mode, `busy_timeout` 5000 and `synchronous` NORMAL, the journal mode switched with the SDK's retry of a busy database, its directory created when missing and the file made 0600 before SQLite opens it. A statement outside a transaction that SQLite answers busy (a snapshot made stale by another process's write, which the busy timeout does not wait out) is tried again within two seconds; a statement that failed is prepared afresh, since SQLite's busy answer leaves it unusable. `deleteJob` is one transaction, or joins the caller's.

`MysqlStore($url, $username, $password, pdo:, prefix:)` is the same tables for MySQL 8.0.13 or newer and MariaDB 10.6 or newer (both first class; CI tests MySQL 8.4 and MariaDB 10.11, the current long-term releases), in MySQL's dialect:

```sql
CREATE TABLE IF NOT EXISTS cronwatch_jobs (
  name VARCHAR(255) NOT NULL,
  definition LONGTEXT NOT NULL,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  PRIMARY KEY (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
CREATE TABLE IF NOT EXISTS cronwatch_runs (
  seq BIGINT NOT NULL AUTO_INCREMENT,
  id VARCHAR(255) NOT NULL,
  job VARCHAR(255) NOT NULL,
  status VARCHAR(255) NOT NULL,
  started_at BIGINT NOT NULL,
  finished_at BIGINT,
  duration_ms BIGINT,
  error MEDIUMTEXT,
  output MEDIUMTEXT,
  metrics LONGTEXT NOT NULL DEFAULT ('{}'),
  `trigger` VARCHAR(255) NOT NULL DEFAULT 'run',
  PRIMARY KEY (id),
  UNIQUE KEY cronwatch_runs_seq (seq),
  KEY cronwatch_runs_job_started (job, started_at DESC),
  KEY cronwatch_runs_running (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
CREATE TABLE IF NOT EXISTS cronwatch_state (
  job VARCHAR(255) NOT NULL,
  state LONGTEXT NOT NULL,
  PRIMARY KEY (job)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
```

The columns and values are the SDK's; what differs is only what MySQL needs:

- The JSON columns are `LONGTEXT` holding the SDK's JSON byte for byte, never MySQL's `JSON` type, which reorders keys and rewrites numbers and spacing (MariaDB's `JSON` is text, but one schema serves both). The state's version is read with `COALESCE(CAST(JSON_UNQUOTE(JSON_EXTRACT(state, '$.version')) AS SIGNED), 0)`, which MySQL (whose `JSON_EXTRACT` answers JSON) and MariaDB (whose answers text) both read as a number.
- A `TEXT` column cannot be a primary key, so names and ids are `VARCHAR(255)`, with the `utf8mb4_bin` collation so they compare as bytes, as SQLite and Postgres compare them ("b" and "B" are two jobs; names sort in byte order).
- `seq` breaks ties between runs started in the same millisecond, as SQLite's `rowid` and Postgres's `seq` do. `trigger` is a reserved word, so the statements quote it.
- There is no partial index, so `runs_running` indexes every status. `CREATE INDEX IF NOT EXISTS` is MariaDB's only, so the indexes are declared in the tables.
- There is no `ON CONFLICT`: upserts are `ON DUPLICATE KEY UPDATE`. `compareAndSetState` from version 0 is an `UPDATE` of a row at version 0 and, failing that, an `INSERT` that a row already there refuses (a duplicate key); from any other version it is one conditional `UPDATE`. Neither leans on how the connection counts affected rows, so an app's connection with `FOUND_ROWS` on gives the same answers.
- MySQL refuses a subquery on the table a `DELETE` deletes from, so `prune` joins in the newest start per job as a grouped derived table.
- MySQL counts only the rows an `UPDATE` changed, so `updateRunIf` over a row that already held those values answers 0; the store then reads the row and counts the write as made when it matches.

Given a URL or DSN (`mysql://` or `mariadb://`, or a `mysql:` DSN; `DATABASE_URL` when given nothing) it opens a connection of its own, utf8mb4, native prepares, in autocommit mode, so its writes never join a transaction the app has open (a run recorded inside one survives a rollback), and connects again once when the server has gone away (errors 2006 and 2013) outside a transaction. Given the app's `PDO` it shares it, transactions and all. `init()` runs `CREATE TABLE IF NOT EXISTS`, which MySQL commits at once; the framework integrations will run it as a migration instead.

Postgres (`pdo_pgsql`) is phase 2, with `sql.ts`'s Postgres text as the Python port has it.

## Frameworks

Each integration maps the framework's scheduler onto jobs and gives the check a home. The core above is what they share; each is its own package or entry class, needing only its framework.

- **Plain crontab.** A script wraps its work in `$job->run()`; a second crontab line runs a small script that declares the jobs and calls `$cw->check()` every five minutes. A `vendor/bin/cronwatch check` command that loads the app's configuration file is planned for phase 2, so that line needs no script of its own.
- **Laravel.** A service provider reads `config/cronwatch.php` (store from the app's database connection, MySQL, SQLite or Postgres, through its PDO or its own connection; channels), publishes a migration, and binds the client. Each scheduled event (`Schedule::command()`, `->job()`, `->call()`) becomes a job named after its command or description, its cron expression and timezone read from the event (`$event->expression`, `$event->timezone`), recorded through the scheduler's `before`/`onSuccess`/`onFailure` hooks, or the `ScheduledTaskStarting`, `ScheduledTaskFinished` and `ScheduledTaskFailed` events, with the run's output from the event's output file. `php artisan cronwatch:check` is scheduled every five minutes by the provider. Queued jobs (`ShouldQueue`) that are not scheduled can use a job middleware for failures and duration.
- **Symfony Scheduler.** A bundle registers the client as a service and listens to Scheduler's `PreRunEvent`, `PostRunEvent` and `FailureEvent` for each message of a schedule, taking the job's name from the message and its schedule from the `RecurringMessage` trigger (a `CronExpressionTrigger` gives its expression; a `PeriodicalTrigger` becomes `every <interval>`). Messages dispatched through Messenger are recorded where they are handled, so a run is its handler's work, not its dispatch. A `cronwatch:check` console command, and a recurring message that runs it.
- **WordPress.** A plugin, since WP-Cron is where missed runs are most common: it fires only when someone visits the site, so a quiet site's events run late or not at all, and that is exactly what CronWatch reports. It hooks each scheduled event (`wp_get_scheduled_event`, `wp_get_schedules` for its recurrence in seconds, as `every <n>s`) and wraps its callbacks, keeps the tables through `$wpdb` (MySQL or MariaDB, which is where WordPress sites are) with the site's table prefix, shows the dashboard in wp-admin, and sends through `wp_mail` as well as the channels. It recommends a real system cron (`DISABLE_WP_CRON` and a crontab line calling `wp-cron.php`), and a missed run is how a site learns it needs one.
- **Drupal.** A module: `hook_cron` implementations run as one cron run per module, recorded by decorating the cron service (each implementation a job named `drupal:<module>`), and the Ultimate Cron and Scheduler contrib modules' jobs mapped when present. Storage through Drupal's database connection. `drush cronwatch:check`.
- **Craft CMS.** A plugin: console commands run by the host's crontab and queue jobs (`craft\queue\BaseJob`) recorded through the queue's `EVENT_BEFORE_EXEC`, `EVENT_AFTER_EXEC` and `EVENT_AFTER_ERROR`, schedules declared in the plugin's settings, since Craft has no scheduler of its own. Storage through Craft's database component.

## Phases

1. Done: the design, the core (durations, schedules with a port of croner, evaluation, stats, output capping and redaction, formatting, serialization, the client with runs, handles, sources, recordRun, deferred delivery and triage hooks), the memory, SQLite and MySQL (and MariaDB) stores, the conformance replay, the SDK's client and store tests, and the finish-once tests with real processes.
2. Everything that needs no web: the Postgres store (`pdo_pgsql`), the alert channels (on PHP's streams, or curl when loaded, no redirects followed, one ten second deadline), Claude triage (the Messages API over HTTP, as `triage/anthropic.ts` sends it, with the official PHP SDK when installed), the pg_cron source, and `vendor/bin/cronwatch`.
3. The web dashboard and JSON API: one handler over PSR-7 requests and responses (with a small built-in front controller for apps without a framework), the SDK routes' URLs, JSON shapes, auth, CSRF, CSP and headers, and the pages matching `packages/ruby/test/web/golden.json` byte for byte.
4. Laravel and Symfony.
5. WordPress, Drupal and Craft.
6. The Packagist release as `cronwatch/cronwatch` (see Releasing), once phase 3 has shipped, so the first release people install has a dashboard.

## Releasing

`src/Cronwatch.php`'s `VERSION` carries the release version, bumped by `scripts/release.mjs` with the others. Packagist reads a package's `composer.json` from the root of a repository and its versions from the repository's tags, so a package in a subdirectory of a monorepo needs one of two things: a read-only split repository (the usual way, as Symfony and Laravel publish their components: a workflow pushes `packages/php` to its own repository, with the tag, on each release, and Packagist watches that repository), or a `composer.json` at the monorepo's root pointing into `packages/php`, with `.gitattributes` `export-ignore` keeping everything else out of the archive Composer downloads. The split repository is recommended; either way `release.mjs` stays as it is (it never publishes) and prints what to do. `composer.lock` is not committed, as the gem's `Gemfile.lock` and the Python package's `uv.lock` are not: a library's lock file is ignored by the apps that install it, and CI resolves the newest dev dependencies each PHP version allows (PHPUnit 11 on 8.2, 12 on newer).

## Where it cannot match the SDK

- A cron expression that names a date no month has (`0 0 30 2 *`) makes croner, which walks by recursion a year at a time, run out of stack before the year 3000, so the SDK reports the job as unevaluable. The port walks in a loop and answers that the schedule never fires: no next expected time, never missed. The Python port is the same.
- Croner reads a string with a colon after its first character as a one-time date, through JavaScript's lenient `Date.parse`. The port refuses every such string: one that looks like an ISO date with `CronPattern: a one-time date is not supported by the PHP port`, anything else with croner's message for text `Date.parse` cannot read. The Python port is the same.
- Without a `timezone`, a cron is read in PHP's default zone (`date_default_timezone_get()`, from `date.timezone`, usually UTC), which is what "local time" means in PHP, where the SDK reads the process's `TZ`. Zone names are matched without regard to case against PHP's zone database, as `Intl` matches them; PHP's abbreviations and offsets (`EST`, `+02:00`), which `new DateTimeZone()` takes, are refused unless they are IANA names.
- Channels and triage run one after another, not at once, and PHP cannot abandon a call that hangs: a channel's timeout is its HTTP client's (phase 2 sets ten seconds, as the SDK's `fetch` has), and triage gets a signal with its 25 second deadline rather than being cut off at it. A diagnosis that arrives late is used. The SDK's tests of a hung channel and of an aborted triage have no PHP counterpart.
- No `start()`/`stop()` interval: see One thing at a time. A check called from inside a check throws rather than waiting for itself.
- Two starts with one id in one process are one after the other in PHP, so the second finds the first's stored run and gets a handle of its own on it, where the SDK hands both callers the same handle.
- `handler()` (a request handler that runs a job) and a `Response` outcome wait for the web phase.
- `expect` patterns are PCRE, not JavaScript regular expressions, and are marked by `Pattern`; one written with `/` delimiters is stored as written (`matches /wrote \d+ files/i`), with only JavaScript's flags kept in the description.
- `cronSecret: false`, not null, opts out of the secret (see The PHP API).
- A `Throwable` passed to `finish()` on its own is a failure, where the SDK treats any object without an `error` key as a result.
- Custom stores implement `Store`, and the conditional writes as two interfaces of their own (`UpdatesRunIf`, `ComparesAndSetsState`), where the SDK checks for the methods.
