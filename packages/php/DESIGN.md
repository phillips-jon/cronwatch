# The PHP port

`packages/php` is `cronwatch/cronwatch` on Packagist (namespace `Cronwatch\`): the same library as `@cronwatch/sdk`, for PHP apps, from a plain crontab script to Laravel, Symfony, WordPress, Drupal and Craft. It is a port, not a new design, made the way the Ruby gem and the Python package were (see their `DESIGN.md`). The TypeScript SDK is the source of truth for every behaviour, message and stored byte; when the two disagree, the PHP side is wrong.

## Rules

- PHP 8.2 or newer, tested on 8.2 and 8.5 in CI (and 8.3 by hand). 8.1 left security support at the end of 2025, and 8.2 is the floor of everything the later phases plug into: Laravel 11 and 12, Symfony 7, Craft 5 and PHPUnit 11 all require it, and Drupal 11 requires 8.3. WordPress still runs on older PHP, but a plugin declares `Requires PHP: 8.2` and WordPress refuses to activate it on anything older, with a message, rather than failing at runtime. The code itself leans on 8.1 (readonly properties, `never`, first-class callables, `array_is_list`); nothing here would be simpler on 8.3, so the floor is set by support and by the frameworks, not by syntax.
- The core has no runtime dependencies beyond `ext-json` and `ext-pcre`, which every PHP has. Cron parsing and fire times are a port of croner 10 (`src/Cron/`, as the Python port's `_cron.py`), zones come from PHP's own zone database, and no `mbstring` or `intl` is needed: UTF-16 lengths, cuts and scrubbing are done on the bytes. The stores need `pdo_sqlite`, `pdo_mysql` or `pdo_pgsql`, named in `suggest` and checked with a clear `LogicException` when missing. The channels and triage use `ext-curl` when it is loaded and PHP's own `http://` streams otherwise, so neither is required; no Composer package is either (triage speaks to the Messages API itself rather than through Anthropic's PHP SDK). An optional piece is its own class, and needs only what it uses.
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
    Alerts/               AlertChannel (the interface), ChannelContext, Console, Custom; Http (the interface), HttpResponse,
                          NativeHttp (curl or streams), RequestTimeout; Shared (shared.ts), Email (email.ts), SigV4;
                          Slack, Discord, Webhook, Resend, Postmark, Sendgrid, Mailgun, Ses, Twilio, Sentry,
                          Honeybadger, Datadog, Rollbar, Bugsnag, NewRelic
    Triage/Anthropic.php  Claude triage over the Messages API (triage/anthropic.ts)
    Sources/              PgCron (sources/pgcron.ts), PgCronPdo (its queries through PDO)
    Store/                Store (the interface), UpdatesRunIf and ComparesAndSetsState (the conditional writes),
                          MemoryStore, Sql (schema, statements, parameters, rows), PdoStore, SqliteStore, MysqlStore,
                          PostgresStore
    Cli.php               vendor/bin/cronwatch
  bin/cronwatch           the Composer bin: `vendor/bin/cronwatch check`
  wordpress/              the WordPress plugin (see Frameworks), built into its own zip
  tests/
    ConformanceTest.php       replays conformance/*.json that the core covers, the store scripts against every store
    ChannelConformanceTest.php  conformance/channels.json: every channel's requests byte for byte
    TriageTest.php            conformance/triage.json: the parameters, the HTTP request, the answers
    PgCronTest.php            conformance/pgcron.json, the SDK's pg_cron tests, and the real extension
    ChannelsTest.php          alerts.test.ts, channels-hardening.test.ts and sigv4.test.ts, and NativeHttp (curl and
                              streams) against a local server (tests/servers/router.php under `php -S`)
    CliTest.php               vendor/bin/cronwatch
    ClientTest.php  ClientHardeningTest.php  StartFinishTest.php  CorrectnessTest.php  ConcurrencyTest.php
                              the SDK's client tests
    StoreConformanceTest.php  store-conformance.ts, for memory, SQLite (in memory and on disk), MySQL, MariaDB and
                              Postgres
    FinishOnceTest.php        finish-once and concurrency with real processes (tests/workers/worker.php) on SQLite,
                              MySQL, MariaDB and Postgres
    SqliteStoreTest.php  MysqlStoreTest.php  PostgresStoreTest.php  JsTest.php
    ShutdownTest.php          a run ended by exit() or a fatal error is recorded (tests/workers/interrupted.php)
    NodeCompatTest.php        one SQLite file shared with the built SDK (tests/node/node_store.mjs)
    ScheduleFuzzTest.php      generated expressions answered by croner itself (tests/node/schedule_fuzz.mjs)
    WordPress/                the plugin against a real WordPress (see Frameworks)
    Support/                  the test clock, a capturing channel, a fake and a real HTTP server, stores that fail or
                              interleave on cue, backends
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

Channels are sent to one after another, and triage is asked in turn, since PHP cannot run them at once or abandon one that hangs. Each gets its deadline instead: triage is handed an `AbortSignal` that aborts after 25 seconds (`remainingMs()` for the request's own timeout), and every channel request has a ten second deadline, as the SDK's `fetch` has. A diagnosis that arrives late is used rather than thrown away.

## Channels

A channel implements `Alerts\AlertChannel` (`name()` and `send(Alert, ChannelContext)`, which throws when the alert went nowhere), or is any callable, which becomes a `Custom` channel named "custom"; one that takes two arguments also gets the `ChannelContext`, whose `onError()` reports a problem that did not stop the alert as `alert channel <name>`. `Console` is the default (standard error on the command line, PHP's error log elsewhere).

The SDK's channels are here, request for request, as the gem's and the Python package's are: `Slack`, `Discord` and `Webhook` (HMAC-SHA256 signature in `X-CronWatch-Signature`), the email providers `Resend`, `Postmark`, `Sendgrid`, `Mailgun` and `Ses` (signed with SigV4, checked against the AWS test suite, so no AWS SDK), `Twilio` for SMS, and the trackers `Sentry`, `Honeybadger`, `Datadog`, `Rollbar`, `Bugsnag` and `NewRelic`. Their options are named arguments with the SDK's names (`new Resend(apiKey: ..., from: ..., to: [...], subjectPrefix: '[prod]', link: fn (Alert $a) => ...)`), so `ChannelConformanceTest` builds each straight from the fixture's options, and replays `conformance/channels.json`: every request's URL, headers and body, byte for byte, for thirteen sample alerts and 29 option sets, the error each channel gives for a refused request, Twilio's partial delivery, and the text cuts. As in the SDK:

- One deadline, ten seconds, for the whole request (connecting, sending and reading the answer): past it before an answer is `RequestTimeout` ("The operation was aborted due to timeout"), past it while the body arrives is the answer with an empty body.
- A redirect is refused, not followed, so credential headers never reach where it points: its 3xx is an answer like any other outside 2xx, and the send fails.
- A failure names the provider and the URL's origin only (a webhook's path or query is often its credential), plus the start of the answer with every secret the channel holds cut out before it is cut to 200 characters on a code point, so no piece of a secret survives at the edge.
- Credentials are trimmed of the spaces and newlines a paste leaves; a header value with a line break inside is refused.
- Ids are deterministic (the first 32 hex characters of SHA-256 over job, type and time), so Resend's idempotency key, Sentry's event id and Rollbar's UUID drop a resend of an alert a provider already took.
- Twilio sends one message per number, fitted to the segments allowed (GSM-7 at 153 a segment or UCS-2 at 67 once split, the extension table costing two, a character never split across two), the link kept whole. The alert counts as delivered when any number took it, each refusal going to `onError` with the number masked; it fails only when every number refused it.

The requests go through `Alerts\Http` (`post($url, $body, $headers, $timeoutMs)`), which every channel takes as `http:`. The default, `NativeHttp`, uses curl when the extension is loaded and PHP's streams otherwise (both tested against a local `php -S` server: the redirect, the deadline, a body that drips in, trimmed headers); the WordPress plugin passes one on `wp_remote_post`, and the tests a fake. Text JavaScript would cut through a surrogate pair (Slack's and Discord's `slice`, triage's prompt) keeps the lone half, as `Js::slice16()`, and `Js::stringify` writes it `\ud83d` as `JSON.stringify` does, so even those bodies are the SDK's bytes.

## Triage

`Triage\Anthropic` is `triage/anthropic.ts` without the Anthropic client: the Messages API is one POST, so it sends it through `Http` itself, the request the official client makes (conformance/triage.json's `wire` cases, generated by driving the real client with a stub `fetch`): `POST https://api.anthropic.com/v1/messages?beta=true`, `anthropic-version: 2023-06-01`, `anthropic-beta` for the fallback beta, `x-api-key`, and the body byte for byte, the client's own telemetry headers (`x-stainless-*`, its user agent) left out. `new Anthropic(apiKey:, model:, effort:, maxTokens:, fallbacks:, context:, baseUrl:, http:)`, the key defaulting to `ANTHROPIC_API_KEY` and the host to `ANTHROPIC_BASE_URL`. One attempt, no retries, with the smaller of 24 seconds and what the client's signal has left as its deadline; a signal already aborted sends nothing. A refused request is reported as `Anthropic https://api.anthropic.com answered <status>: <body>` with the key cut out, to `onError` as `triage for <job>`, and the alert goes out without a diagnosis.

## Sources

`sources:` takes objects implementing `Source` (`name()` and `sync(Cronwatch $host)`), as the SDK's `sources` does. `check()` calls each, in order, after the store is ready and before anything else; one that throws is reported as `source <name>` and the check carries on, and the alerts a sync returns are added to the check's result. The host is the client: `job()`, `recordRun()`, `$store`, `now()` and `onError()`. `recordRun($run, evaluate: true)` is the SDK's `recordRun`, claim and all.

`Sources\PgCron($db, jobs:, prefix:, jobName:, options:, timezone:)` is `sources/pgcron.ts`. On each check it reads `cron.job` and declares each job with its schedule from pg_cron: `$` read as `L`, `N seconds` as `every Ns`, fields past the fifth dropped, and a paused job declared without its schedule. It then copies new rows of `cron.job_run_details` in as runs with ids `pgcron:<prefix><runid>`: the twenty newest quietly on first sight, 500 a page and ten pages a check. A run queued without a start time is held ten minutes. A renamed, unscheduled or unpicked job's old name is declared again without its schedule, so it is never missed. It reads through a `pdo_pgsql` PDO, a `postgres://` URL (a connection of its own), or any object with `query(string $sql, array $params): array`, which is handed the SDK's SQL with `$1` placeholders and PHP arrays for the array parameters; through PDO, arrays are bound as Postgres array literals. Settings are read from `pg_settings`, which never raises, so a role that may not read them never aborts the caller's transaction. Timestamps arrive from `pdo_pgsql` as text and are read as the SDK's driver reads them: pg's postgres-date takes the fraction as 1000 times its value, cut to whole milliseconds. `PgCronTest` replays `conformance/pgcron.json`, ports the SDK's (and the Python package's) source tests against a fake `cron` schema, and runs four more against the real extension when `CRONWATCH_TEST_PGCRON` names a Postgres with pg_cron preloaded.

## Keeping in step

`conformance/` at the repo root holds JSON cases generated from the TypeScript build by `scripts/conformance.mjs`. `ConformanceTest` replays every case the core covers (duration, schedule, evaluate, format, health, output, and the store scripts against the memory, SQLite, MySQL, MariaDB and Postgres stores), comparing values as the JSON the SDK writes; `ChannelConformanceTest`, `TriageTest` and `PgCronTest` replay the channel, triage and pg_cron fixtures; and a fixture file nothing replays fails the suite. A behaviour change lands in TypeScript first, `npm run conformance` regenerates the fixtures, and this package is fixed until they pass. Phase 1 needed nothing new in the fixtures. Phase 2 added one thing: `triage.json`'s `wire` cases, the HTTP request the official Anthropic client makes for a triage (URL, the headers that carry meaning, the body), since this port makes that request itself.

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

`PostgresStore($url, $username, $password, pdo:, prefix:)` is `stores/postgres.ts` through `pdo_pgsql`. It keeps the same three tables, `CREATE` text and statements as `sql.ts`'s Postgres dialect: JSONB for the JSON columns, BIGINT times, `seq BIGSERIAL` breaking ties between runs started in the same millisecond, and `name COLLATE "C"` so names sort in byte order whatever the database's collation. The statements are written with `?`, which PDO's native prepare numbers `$1`, `$2` in order, so the server sees the SDK's text. Given a URL or DSN (`postgres://` or `postgresql://` with query parameters such as `sslmode` passed to libpq, a `pgsql:` DSN, or `DATABASE_URL` when given nothing) it opens a connection of its own in autocommit mode, so its writes never join a transaction the app has open. It connects again once when the connection broke outside one of its own transactions (SQLSTATE class 08, or 57P01 to 57P03); libpq reports a broken connection as inside a transaction, so the store keeps its own count. Given the app's `PDO` it shares it, transactions and all. `init()` takes `pg_advisory_xact_lock(hashtext('cronwatch:<prefix>'))` in one transaction before `CREATE TABLE IF NOT EXISTS`, so processes starting at once take turns. JSONB orders an object's keys by length and then bytes, so a definition, a state or a run's metrics read back from Postgres has its keys in that order, as the SDK reads it; the values are the same. The store passes the store contract, the store fixtures and the finish-once tests with real processes, as the others do.

## Frameworks

Each integration maps the framework's scheduler onto jobs and gives the check a home. The core above is what they share; each is its own package or entry class, needing only its framework.

- **Plain crontab.** A script wraps its work in `$job->run()`, and a second crontab line runs the check every five minutes: `vendor/bin/cronwatch check`, a Composer bin, so that line needs no script of its own. It finds the app's client in a bootstrap file, a PHP file that returns the `Cronwatch` client with its jobs declared (or a callable that returns it), the same file the app's own scripts can `require`: `--bootstrap <file>`, else `CRONWATCH_BOOTSTRAP`, else `cronwatch.php`, else `config/cronwatch.php` in the working directory. Composer's autoloader is loaded first (the one Composer 2.2 and newer name to a bin script, else found by path). It prints the line the gem's rake task and the Python package's `cronwatch_check` print, `cronwatch: checked 3 jobs, sent 1 alert` (`--quiet` for none), and exits 0; anything that goes wrong is one line on standard error and exit status 1, so cron mails it. `CheckResult::summary()` is that line, for the framework commands to print.
- **Laravel.** A service provider reads `config/cronwatch.php` (store from the app's database connection, MySQL, SQLite or Postgres, through its PDO or its own connection; channels), publishes a migration, and binds the client. Each scheduled event (`Schedule::command()`, `->job()`, `->call()`) becomes a job named after its command or description, its cron expression and timezone read from the event (`$event->expression`, `$event->timezone`), recorded through the scheduler's `before`/`onSuccess`/`onFailure` hooks, or the `ScheduledTaskStarting`, `ScheduledTaskFinished` and `ScheduledTaskFailed` events, with the run's output from the event's output file. `php artisan cronwatch:check` is scheduled every five minutes by the provider. Queued jobs (`ShouldQueue`) that are not scheduled can use a job middleware for failures and duration.
- **Symfony Scheduler.** A bundle registers the client as a service and listens to Scheduler's `PreRunEvent`, `PostRunEvent` and `FailureEvent` for each message of a schedule, taking the job's name from the message and its schedule from the `RecurringMessage` trigger (a `CronExpressionTrigger` gives its expression; a `PeriodicalTrigger` becomes `every <interval>`). Messages dispatched through Messenger are recorded where they are handled, so a run is its handler's work, not its dispatch. A `cronwatch:check` console command, and a recurring message that runs it.
- **WordPress.** A plugin, since WP-Cron is where missed runs are most common: it fires only when someone visits the site, so a quiet site's events run late or not at all, and that is exactly what CronWatch reports. The source is `wordpress/` (`cronwatch.php`, `uninstall.php`, `readme.txt`, `includes/` in the namespace `Cronwatch\WordPress`); `php wordpress/build.php` makes the plugin directory's zip, `cronwatch/` with the plugin, the library's `src/` in `lib/src` and its MIT text in `lib/LICENSE`, nothing else, byte for byte the same on every build, and refuses to build unless `Cronwatch::VERSION`, the header's `Version` and the readme's `Stable tag` agree (`release.mjs` bumps all three).
  - *Licence.* The directory requires GPL or GPL compatible code. The plugin itself is GPLv2 or later; it bundles this library under MIT, which is GPL compatible, so the zip as a whole is distributable under the GPL while the library stays MIT for everyone else. The readme says so.
  - *Watching WP-Cron with no code changes.* The plugin observes `pre_reschedule_event` and `pre_unschedule_event` (returning `$pre` untouched), which wp-cron.php and WP-CLI's `wp cron event run` pass through just before `do_action_ref_array()`, to note the event about to run. On first sight of a hook it adds a callback at `PHP_INT_MIN` that starts a run (`trigger: "wp-cron"`) and one at `PHP_INT_MAX` that finishes it, keeping what the callbacks echo as the output (echoed back unchanged) after any `cronwatch_log()` lines. A hook fired without a matching note (a `do_action()` by hand) is not a run.
  - *Jobs.* A recurring event is `wp:<hook>` with schedule `every <interval>s` from its recurrence (`hourly` 3600, `twicedaily` 43200, `daily` 86400, `weekly` 604800, custom ones from `cron_schedules`); one with arguments is `wp:<hook>:<key>`, the key the first 8 hex characters of WordPress's own `md5(serialize($args))`, so each set of arguments is its own job. Single events are one job per hook without a schedule: one-offs have no cadence to miss, and the recurring core events (`wp_version_check` and the rest, watched like any other) show whether WP-Cron fires at all. A hook with characters outside the job name rules has them turned into `-`, and one that had to be changed or cut gets `-<8 hex of md5(hook)>`, so two hooks never collide. Jobs are tagged `wp-cron`, described by hook, arguments and recurrence, and adjustable by filters (`cronwatch_watch_event`, `cronwatch_job_options`). An event gone from the cron array (its plugin deactivated) has its job declared again without a schedule at the next check, so it is never reported missed.
  - *Failures.* An uncaught exception, a fatal error or `exit()` in a callback records the run as failed with phase 1's text (`Interrupted: Fatal error: <message>` and its `file:line`, or `Interrupted: the process exited during the run`). WordPress's fatal error handler is a shutdown function registered before any plugin's, and it shows its page through `wp_die()`, which exits and so stops every later shutdown function; the plugin records its open runs from inside that path (the `wp_php_error_message` and `wp_die_handler` filters) and from its own shutdown function when the handler is off or output was already sent. Checked under WP-CLI and under a real wp-cron.php request.
  - *Storage.* `WpdbStore` keeps the MySQL dialect's three tables through `$wpdb`, named with the site's prefix and `cronwatch_` (capitals allowed, as WordPress allows them in prefixes), values rendered through `$wpdb->prepare()`; the stored bytes are `MysqlStore`'s, which a test checks column by column on one database. The tables are made on activation with `CREATE TABLE IF NOT EXISTS`, not `dbDelta()`, which would keep "fixing" the descending index and the expression default; `cronwatch_db_version` marks the schema for later migrations, and a site of a network gets its tables when first used. It needs MySQL 5.7.8 or MariaDB 10.3 (`JSON_EXTRACT`, and the long index keys utf8mb4 needs); before MySQL 8.0.13 the metrics column goes without its `DEFAULT ('{}')`, which changes no stored value since every writer gives metrics. Activation refuses older servers with a message.
  - *The check.* The plugin runs it from its own WP-Cron event every five minutes and from `wp cronwatch check` (the line every port prints). A check that runs when someone visits cannot notice a site nobody visits, so the readme recommends `DISABLE_WP_CRON` and a system crontab calling `wp cron event run --due-now` (or wp-cron.php) and `wp cronwatch check`, and a missed run is how a site learns it needs one.
  - *Settings.* Tools > CronWatch, behind `manage_options` and a nonce on every form: email through `wp_mail` (a WordPress channel composing the library's email), a Slack URL and a webhook URL and secret (the library's channels, over `wp_remote_post` with no redirects and a ten second timeout, as the plugin directory prefers to direct curl), grace, a test alert, and the watched jobs' health. Nothing leaves the site until a channel is set; with none, alerts go to the error log. Options and events are prefixed `cronwatch_`; `uninstall.php` drops the tables and removes every option and event, on every site of a network. Developers get `cronwatch_alerts` and `cronwatch_client_args`. The dashboard in wp-admin is phase 3, and the page says so.
  - *Floors.* `Requires PHP: 8.2`, the library's. `Requires at least: 6.1`, the first WordPress that supports PHP 8.2, on a branch still given security releases; the hooks used need only 5.7.
  - *Tests.* `tests/WordPress/WordPressTest.php` installs WordPress with WP-CLI into a temporary directory against a real MySQL or MariaDB (`CRONWATCH_TEST_WORDPRESS`, a `mysql://` URL; `CRONWATCH_TEST_WPCLI`, the phar; `CRONWATCH_TEST_WP_VERSION`, default the current release, 6.1.14 on CI's PHP 8.2), installs the built zip, and drives it through `wp` commands, `wp eval-file` and wp-cron.php under `php -S`, with a must-use plugin of test callbacks, clock and channel. The WordPress test suite (`WP_UnitTestCase`, as wp-phpunit or wp-env run it) was passed over: it wraps each test in a transaction and turns `CREATE TABLE` into temporary tables, which hides what needs testing here (real tables, `uninstall.php`, a fatal error that ends the process, a wp-cron.php request), and it trails PHPUnit's current majors. `tests/WordPress/PluginTest.php` checks the naming, the schema per server and the zip's contents without WordPress.
- **Drupal.** A module: `hook_cron` implementations run as one cron run per module, recorded by decorating the cron service (each implementation a job named `drupal:<module>`), and the Ultimate Cron and Scheduler contrib modules' jobs mapped when present. Storage through Drupal's database connection. `drush cronwatch:check`.
- **Craft CMS.** A plugin: console commands run by the host's crontab and queue jobs (`craft\queue\BaseJob`) recorded through the queue's `EVENT_BEFORE_EXEC`, `EVENT_AFTER_EXEC` and `EVENT_AFTER_ERROR`, schedules declared in the plugin's settings, since Craft has no scheduler of its own. Storage through Craft's database component.

## Phases

The owner set this order on 2026-09-28, moving WordPress up to phase 2: WP-Cron fires only when someone visits the site, so missed runs are more common there than anywhere else CronWatch watches.

1. Done: the design, the core (durations, schedules with a port of croner, evaluation, stats, output capping and redaction, formatting, serialization, the client with runs, handles, sources, recordRun, deferred delivery and triage hooks), the memory, SQLite and MySQL (and MariaDB) stores, the conformance replay, the SDK's client and store tests, and the finish-once tests with real processes.
2. Done: the Postgres store (`pdo_pgsql`), every alert channel (curl when loaded, PHP's streams otherwise, no redirects followed, one ten second deadline), Claude triage over plain HTTP, the pg_cron source, `vendor/bin/cronwatch`, the WordPress plugin (tested against a real WordPress, built into a zip for the plugin directory), and the split repository workflow for Packagist, switched off.
3. The web dashboard and JSON API: one handler over PSR-7 requests and responses (with a small built-in front controller for apps without a framework), the SDK routes' URLs, JSON shapes, auth, CSRF, CSP and headers, and the pages matching `packages/ruby/test/web/golden.json` byte for byte; and the dashboard in wp-admin.
4. Laravel and Symfony.
5. Drupal and Craft.

The first Packagist release comes after phase 3, so the first release people install has a dashboard; nothing is published before then. The plugin's zip is built and checked from phase 2 on; when it is first submitted to the plugin directory is the owner's call.

## Releasing

`src/Cronwatch.php`'s `VERSION` carries the release version, bumped by `scripts/release.mjs` with the others. Packagist reads a package's `composer.json` from the root of a repository and its versions from the repository's tags, so a package in a subdirectory of a monorepo is published through a read-only split repository, as Symfony and Laravel publish their components: `.github/workflows/php-split.yml` runs on each release tag (`v*`, which `release.mjs` makes and the owner pushes), checks that `Cronwatch::VERSION` is the tag's version, takes `git subtree split --prefix=packages/php` (the same commits for the same history every time, so each push fast-forwards), and pushes it to the split repository's `main` with the tag. Packagist watches that repository. `packages/php/.gitattributes` keeps the tests, the PHPUnit configuration and the WordPress plugin's source out of the archive Composer downloads. `release.mjs` still never publishes; it prints that the tag carries the release.

The workflow does nothing until it is switched on. The owner's steps, once, before the first release (after phase 3):

1. Create the split repository, empty, public, read-only by convention (`phillips-jon/cronwatch-php`, say), with its description pointing back to this monorepo for issues and pull requests.
2. Make an SSH key pair (`ssh-keygen -t ed25519 -N "" -f cronwatch-php-split`). Add the public half to the split repository as a deploy key with write access (Settings, Deploy keys), and the private half to this repository as the secret `PHP_SPLIT_DEPLOY_KEY` (Settings, Secrets and variables, Actions). A deploy key reaches that one repository only, where a personal token would reach every repository the account can.
3. Set this repository's variables `PHP_SPLIT_REPOSITORY` to `phillips-jon/cronwatch-php` and `PHP_SPLIT_ENABLED` to `true`.
4. Run the workflow by hand for the current release tag (Actions, PHP split, Run workflow) so the split repository has a `main` and a tag.
5. On packagist.org, sign in with GitHub, submit the split repository's URL (the package name comes from its `composer.json`: `cronwatch/cronwatch`), and let Packagist's GitHub integration install its hook, so each pushed tag appears as a version within a minute. Add a second maintainer if there is one.

From then on a release is: `npm run release -- <version>`, then `git push origin main v<version>`; the split and Packagist follow. `composer.lock` is not committed, as the gem's `Gemfile.lock` and the Python package's `uv.lock` are not: a library's lock file is ignored by the apps that install it, and CI resolves the newest dev dependencies each PHP version allows (PHPUnit 11 on 8.2, 12 on newer).

## Where it cannot match the SDK

- A cron expression that names a date no month has (`0 0 30 2 *`) makes croner, which walks by recursion a year at a time, run out of stack before the year 3000, so the SDK reports the job as unevaluable. The port walks in a loop and answers that the schedule never fires: no next expected time, never missed. The Python port is the same.
- Croner reads a string with a colon after its first character as a one-time date, through JavaScript's lenient `Date.parse`. The port refuses every such string: one that looks like an ISO date with `CronPattern: a one-time date is not supported by the PHP port`, anything else with croner's message for text `Date.parse` cannot read. The Python port is the same.
- Without a `timezone`, a cron is read in PHP's default zone (`date_default_timezone_get()`, from `date.timezone`, usually UTC), which is what "local time" means in PHP, where the SDK reads the process's `TZ`. Zone names are matched without regard to case against PHP's zone database, as `Intl` matches them; PHP's abbreviations and offsets (`EST`, `+02:00`), which `new DateTimeZone()` takes, are refused unless they are IANA names.
- Channels and triage run one after another, not at once, and PHP cannot abandon a call that hangs: a channel's timeout is its HTTP request's (ten seconds, as the SDK's `fetch` has), and triage gets a signal with its 25 second deadline rather than being cut off at it; the triage request's own deadline is what the signal has left. A diagnosis that arrives late is used. The SDK's tests of a hung channel and of an aborted triage have no PHP counterpart.
- Twilio texts its numbers one after another, in the order given, where the SDK texts them at once; each request has its own ten second deadline, so three unreachable numbers can hold a check for thirty seconds.
- Triage sends the official Anthropic client's request without that client: the same URL, `anthropic-version`, `anthropic-beta`, `x-api-key` and body, but its own user agent (`cronwatch-php/<version>`) and none of the client's `x-stainless-*` telemetry headers. The key comes from `apiKey` or `ANTHROPIC_API_KEY`; the client's `ant auth login` profiles are not read. A refused request's error is CronWatch's (`Anthropic https://api.anthropic.com answered 529: ...`), not the client's error classes.
- A channel's name in its constructor's error is its class (`Resend needs an apiKey`) where the SDK names its function (`resend() needs an apiKey`).
- Postgres gives a JSON column's object keys back in JSONB's order (by length, then bytes), as it does to the SDK; the store contract test compares key order for every store but Postgres. A pg_cron run id is recognised as up to fifteen digits, where the SDK's `Number()` would also read `""` as 0 (only a hand-made id tells them apart), and pg_cron's `options` drop a `schedule` or `timezone` given in them, where the SDK's types forbid them.
- No `start()`/`stop()` interval: see One thing at a time. A check called from inside a check throws rather than waiting for itself.
- Two starts with one id in one process are one after the other in PHP, so the second finds the first's stored run and gets a handle of its own on it, where the SDK hands both callers the same handle.
- `handler()` (a request handler that runs a job) and a `Response` outcome wait for the web phase.
- `expect` patterns are PCRE, not JavaScript regular expressions, and are marked by `Pattern`; one written with `/` delimiters is stored as written (`matches /wrote \d+ files/i`), with only JavaScript's flags kept in the description.
- `cronSecret: false`, not null, opts out of the secret (see The PHP API).
- A `Throwable` passed to `finish()` on its own is a failure, where the SDK treats any object without an `error` key as a result.
- Custom stores implement `Store`, and the conditional writes as two interfaces of their own (`UpdatesRunIf`, `ComparesAndSetsState`), where the SDK checks for the methods.
