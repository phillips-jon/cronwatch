---
title: PHP
description: cronwatch/cronwatch in plain PHP: jobs, crontab scripts, vendor/bin/cronwatch check, the dashboard, stores, alert channels, Claude triage, pg_cron, and sharing one database with Node, Ruby, Python, Go, Rust, Elixir, Java and .NET.
order: 3.76
group: PHP
---

# PHP

`cronwatch/cronwatch` is a port of `@cronwatch/sdk`, not a new design. It decides missed, failed, stuck, slow and over budget by the same rules, sends the same alert text, and writes the same rows, so a PHP process can share one database with a Node, Ruby, Python, Go, Rust, Elixir, Java or .NET process and the [MCP server](/docs/mcp/) works against any of them. This page covers plain PHP (crontab scripts, a bare `public/` script, any PSR-15 stack) and the API underneath. The frameworks have pages of their own: [Laravel](/docs/laravel/), [Symfony](/docs/symfony/), [WordPress](/docs/wordpress/), [Drupal](/docs/drupal/) and [Craft CMS](/docs/craft/).

```bash
composer require cronwatch/cronwatch
```

PHP 8.2 or newer, with no dependencies beyond `ext-json` and `ext-pcre`, which every PHP has: cron expressions are read by a port of [croner](https://github.com/hexagon/croner), the parser the SDK uses, and zones come from PHP's own zone database. The rest needs only the extension it uses:

| Class | For | Needs |
|---|---|---|
| `Cronwatch\Cronwatch` | the client, the memory store, the console channel | nothing |
| `Cronwatch\Store\SqliteStore` | one SQLite file | `pdo_sqlite` |
| `Cronwatch\Store\MysqlStore` | MySQL 8.0.13 or newer, MariaDB 10.6 or newer | `pdo_mysql` |
| `Cronwatch\Store\PostgresStore` | Postgres | `pdo_pgsql` |
| `Cronwatch\Alerts\...` | Slack, Discord, webhook, email, SMS and error tracker channels | `ext-curl` when it is loaded, PHP's own streams otherwise |
| `Cronwatch\Triage\Anthropic` | Claude triage | the same; no Anthropic package |
| `Cronwatch\Sources\PgCron` | watching pg_cron's jobs | `pdo_pgsql` |
| `Cronwatch\Web\PsrHandler`, `PsrMiddleware`, `PsrJobHandler` | the dashboard and `handler()` in a PSR-15 stack | `psr/http-server-handler` (and `psr/http-server-middleware` for the middleware), with a PSR-7 and PSR-17 implementation such as `nyholm/psr7` |

A store made without its extension throws a `LogicException` that names it. Over PHP's streams, an `https` channel needs `ext-openssl`.

## Create one client

Put the client in a file that returns it. Your scripts `require` it, and so does the check command below:

```php
<?php
// cronwatch.php, at the project's root
require __DIR__ . '/vendor/autoload.php';

use Cronwatch\Alerts\Slack;
use Cronwatch\Cronwatch;
use Cronwatch\Store\SqliteStore;

$cw = new Cronwatch(
    store: new SqliteStore(__DIR__ . '/data/cronwatch.db'),
    alerts: [new Slack(getenv('SLACK_WEBHOOK_URL'))],
    retention: '30d',
);

$cw->job('nightly-report', [
    'schedule' => '0 2 * * *', 'timezone' => 'UTC', 'grace' => '15m', 'timeout' => '30m',
    'expect' => 'Report written', 'budget' => ['cost' => 2],
]);

return $cw;
```

The client takes named arguments. Without a store, runs live in memory and are gone when the process ends, which for PHP is usually the end of the script or the request; the client warns about it in production. Without alerts, they go to the console: standard error on the command line, PHP's error log anywhere else.

## Declare and run a job

```php
<?php
// bin/nightly-report.php
use Cronwatch\Job\JobContext;

$cw = require __DIR__ . '/../cronwatch.php';

$nightly = $cw->job('nightly-report', [
    'schedule' => '0 2 * * *', 'timezone' => 'UTC', 'grace' => '15m', 'timeout' => '30m',
    'expect' => 'Report written', 'budget' => ['cost' => 2],
]);

$nightly->run(function (JobContext $job) {
    $path = build_report();
    $job->log('Report written:', $path);   // kept with the run, shown in alerts
    $job->metric('cost', 1.2);             // watched against budgets and baselines
});
```

```
0 2 * * *    cd /var/www/app && php bin/nightly-report.php
```

The run is recorded when the function returns. What it throws (an `Exception` or an `Error`) is recorded as the failure and thrown again, so your own error handling still works and the script still exits non-zero.

A run cut short by `exit()` or a fatal error, such as memory running out, which no `catch` sees, is recorded as failed when the process ends (`Interrupted: the process exited during the run`, or `Interrupted: Fatal error: <message>` with the file and line), so it is never left running to be reported stuck later. A process killed outright records nothing, and its run is marked stuck after the job's timeout.

`run()` returns what the function returns, and a string it returns is the run's output when nothing was logged. `wrap()` gives a callable whose every call is a run, with `Cronwatch::current()` as its context:

```php
$report = $nightly->wrap(function (string $day) {
    \Cronwatch\Cronwatch::current()?->log('Report written for', $day);
});
$report('2026-09-28');
```

Without keeping a handle, `$cw->run('nightly-report', $fn, $options)` declares the job on first use (or again, when given options) and runs it.

Options are an array with the SDK's names (`maxDuration`, `failuresBeforeAlert`), and an unknown key is refused with an `InvalidArgumentException`, so a typo is found when the job is declared. Durations are strings such as `'15m'` or `'1h30m'`, milliseconds, or a `DateInterval`; a duration string over 64 characters is refused with an `InvalidArgumentException`.

`expect` is a string the output must contain, a `Cronwatch\Pattern` it must match (`new Pattern('/wrote \d+ files/i')`), or a callable given the output; a plain string is always a substring, since PHP has no regular expression type to tell the two apart. A `Pattern` runs on PCRE, which stops at its backtrack limit (`pcre.backtrack_limit`) rather than run on: a pattern that gives up there counts as not matching, and the run fails with `Output did not match /.../ (Backtrack limit exhausted)`. Anchor a pattern where you can and avoid a repeat inside another over the same characters; see [expect rules](/docs/conditions/#expect-rules).

The context has `name`, `runId`, `startedAt`, `log(...$parts)`, `metric($name, $value)`, `metrics([...])`, `aborted()` and `signal`, which aborts once the job's `timeout` has passed. Nothing is interrupted: a loop that can stop early checks `$job->aborted()`.

A file that says `use Cronwatch\Cronwatch;` should import the other classes too (`use Cronwatch\Alert;`) or write them with a leading backslash (`\Cronwatch\Alert`): with that line in place, PHP reads `Cronwatch\Alert` as `Cronwatch\Cronwatch\Alert`.

## Run the check

A PHP process does not stay up between runs, so nothing inside a crontab script notices the run that never happened. A second crontab line checks every five minutes:

```
*/5 * * * *  cd /var/www/app && vendor/bin/cronwatch check
```

`vendor/bin/cronwatch check` loads Composer's autoloader, then the bootstrap file, a PHP file that returns the client with its jobs declared (or a callable that returns it), such as `cronwatch.php` above. It looks for `--bootstrap <file>`, then `CRONWATCH_BOOTSTRAP`, then `cronwatch.php`, then `config/cronwatch.php` in the working directory. It runs `check()`, which finds missed and stuck runs, sends their alerts, retries alerts no channel accepted and prunes old runs, and prints one line:

```
cronwatch: checked 3 jobs, sent 0 alerts
```

`--quiet` prints nothing. Anything that goes wrong is one line on standard error and exit status 1, so cron mails it. In a Laravel or Craft CMS app, `config/cronwatch.php` is the framework's settings file rather than a client, so use `php artisan cronwatch:check` or `php craft cronwatch/check` there.

The bootstrap file must declare every job, so a job that never ran at all is known and reported missed. Every job already in the store is checked from its stored definition too.

Run one checker per store. Two checks against one database at the same moment can each send the same alert. `check()` returns a `CheckResult` with `checkedAt`, `jobs`, `alerts` and `pruned`, and `summary()` is the line above. A worker loop (a queue consumer, a daemon) can call `$cw->check()` itself every few minutes instead of the crontab line.

## The dashboard

`$cw->routes()` is the dashboard and JSON API, the same pages and endpoints as the TypeScript routes, byte for byte: the board's counts by health, a timeline of the last day with a lane per job, the table of every job, and for each job its last seven days, runs and definition, all drawn on the server with no script, plus the API the [MCP server](/docs/mcp/) talks to. It needs no framework. In a bare script:

```php
<?php
// public/cronwatch.php: open /cronwatch.php/
$cw = require __DIR__ . '/../cronwatch.php';
$cw->routes()->serve();
```

`serve()` reads the request from PHP's superglobals (including the `Authorization` header Apache hides) and writes the answer with `header()` and `echo`. To serve it at `/cronwatch/` instead, rewrite that path to the script in the web server; the routes then default to `/cronwatch` as their base path.

`handle(Cronwatch\Web\Request): Cronwatch\Web\Response` is the same routes for anything else. With a PSR-7 implementation installed, `Cronwatch\Web\PsrHandler` (a PSR-15 request handler) and `Cronwatch\Web\PsrMiddleware` (it answers under its base path, `/cronwatch` by default, and passes the rest on) take a PSR-17 factory:

```php
$factory = new Nyholm\Psr7\Factory\Psr17Factory();
$app->add(new \Cronwatch\Web\PsrMiddleware($cw->routes(), $factory, $factory));   // Slim, Mezzio, any PSR-15 stack
```

`$cw->routes(token:, basePath:, origin:, trustProxy:)`:

- `token`: leave it out to read `CRONWATCH_TOKEN`; an empty string counts as unset. Everything needs it, as `Authorization: Bearer <token>`, or open the dashboard once with `?token=<token>` and a cookie keeps the browser signed in. `false` serves the routes open, for a mount behind your own auth. Without a token:
  - In development, the routes make one and keep it in a file in the system's temporary directory, so every request, in every PHP process, asks for the same one. They write a sign-in link to the server log when they make it.
  - The link names the host only when `origin` is set or the request's host is loopback: `localhost`, a name ending in `.localhost`, `127.0.0.0/8` or `::1`. The host must read as one of these on its own, so a Host header such as `localhost:1@evil.example` does not count. Otherwise the link leaves the host out, since a client chooses it: `Sign in: /cronwatch/?token=... on this server (the first request's host is not local, so the link leaves it out)`.
  - Anywhere else, they answer 503.
  - The environment is the first of `CRONWATCH_ENV`, `APP_ENV` and `WP_ENVIRONMENT_TYPE` that is set (where the SDK reads `NODE_ENV`); `development`, `dev`, `local`, `test` and `testing` count as development.
- `basePath`: where it is mounted. It defaults to the script for a path-info URL (`/cronwatch.php`), else `/cronwatch`.
- `origin`: the public origin, such as `'https://app.example.com'`, to pin it whatever a request says. It then replaces the request's own for the cross-site check on writes, the cookie's `Secure` flag and redirects.
- `trustProxy`: take the origin from the first `X-Forwarded-Proto` and `X-Forwarded-Host`. Off by default.

The token rules, cookie, cross-site rule and every endpoint are the SDK's; see [Dashboard and API](/docs/dashboard/). `/api/check` also accepts the client's `cronSecret` (`CRON_SECRET` by default) as a bearer, so an outside cron can run the check over HTTP. A request body over 1 MiB is answered 413. The dashboard installs as a web app, with its manifest, icons and service worker under the mount point; see [Install it as an app](/docs/dashboard/#install-it-as-an-app).

## Jobs a URL starts

Some platforms run scheduled work by calling a URL: a hosting provider's cron, Cloud Scheduler, an outside cron service, a crontab line running `curl`. `$job->handler($fn)` is that endpoint. It runs `$fn(JobContext $job, $request)` as a recorded run for each request carrying `Authorization: Bearer <secret>`, and answers with JSON saying how the run went:

```php
<?php
// public/cron/nightly.php
use Cronwatch\Job\JobContext;

$cw = require __DIR__ . '/../../cronwatch.php';

$cw->job('nightly-report', ['schedule' => '0 2 * * *', 'timezone' => 'UTC'])
    ->handler(fn (JobContext $job, $request) => build_report($job))
    ->serve();
```

`serve()` answers from the superglobals. Called with a request, the handler answers in that request's kind, so a Symfony controller is `return $handler($request);`; `laravel()` is a Laravel route action and `symfony()` a Symfony controller callable, and `new Cronwatch\Web\PsrJobHandler($handler, $factory, $factory)` is a PSR-15 request handler.

The secret is `handler($fn, secret: '...')`, else the client's `cronSecret`, which reads `CRON_SECRET` by default; it is compared in constant time. A wrong or missing bearer is answered 401 and runs nothing. With no secret at all, outside development, the handler answers 503 and reports it once to `onError`, rather than let anyone on the internet run the job; `secret: false` opts out on purpose, for an endpoint your platform already protects. A run is answered 200 or 500 with `{"ok", "job", "run", "status", "durationMs"}`, and a function that returns a response of its own is answered with it.

A response with a status of 400 or more fails the run, recorded as `HTTP <status>` and its reason (`HTTP 503 Service Unavailable`), whether a handler, `run()` or `finish(['result' => ...])` got it. PSR-7 responses, Symfony's and Laravel's responses, Symfony's HttpClient responses, Laravel's HTTP client responses, a `Cronwatch\Web\Response` and an array such as `['status' => 503, 'body' => 'down']` are all recognised, so a job that calls an API and returns its answer fails when the API does.

## Runs that span calls

A run is normally one call. Work that starts in one place and ends in another (a job that hands work to a queue, a webhook that reports completion later) can be one run too: `start()` records it as running and returns a run handle, and `finish()` on that handle, or on one from `resume($id)` in another process, ends it.

```php
$sync = $cw->job('partner-sync', ['schedule' => '0 * * * *', 'timeout' => '2h']);

$run = $sync->start(id: $batchId);   // records a running run
// later, perhaps in another process
$run = $sync->resume($batchId);      // or $cw->resumeRun('partner-sync', $batchId)
$run->log('imported', $count, 'rows');
$run->finish();                      // or $run->fail($error), or $run->finish('text')
```

`start(trigger: null, id: null)` takes your own stable id, 1 to 200 characters, not starting with `pgcron:`: a start with an id already recorded for this job records nothing and returns a handle on that run. A store that fails is reported to `onError`, never thrown.

The handle has `id`, `job`, `startedAt`, `log()`, `metric()`, `metrics()`, `flush()` (append what is logged so far to the stored run), `finish($outcome)`, `fail($error)` and `isActive()`, false once it is finished.

`finish()` takes nothing (ok), a string or `['result' => $x]` (treated as `run()`'s return value), or a `Throwable` or `['error' => $e]` (failed). A run is judged once however many times it is finished: a second finish, or one on a run another process finished, records nothing, returns null and is reported to `onError`.

A run that is never finished is marked stuck by the first check after the job's `timeout`, so set `timeout` to cover the whole span. The [Ruby page](/docs/ruby/#runs-that-span-calls) has the full rules, which are the same.

## Stores

`Cronwatch\Store\MemoryStore` is the default. It forgets when the process ends, so it is for tests and trying things out.

`new SqliteStore($path = './data/cronwatch.db', pdo: null, prefix: 'cronwatch_')` keeps everything in one file, in WAL mode. The directory is made if it is missing and the file is created private (mode 0600). `pdo:` takes an open `PDO` of your own. The tables, statements and JSON are the SDK's SQLite store's byte for byte, so a Node process using `@cronwatch/sdk/sqlite` on the same file sees the same jobs, runs and state.

`new MysqlStore($url = null, $username = null, $password = null, pdo: null, prefix: 'cronwatch_')` is for MySQL 8.0.13 or newer and MariaDB 10.6 or newer. It takes a `mysql://` (or `mariadb://`) URL, a `mysql:` PDO DSN, or `DATABASE_URL` when given nothing. The URL's TLS parameters are used (`ssl-mode` or `sslmode`, `ssl-ca`, `ssl-cert`, `ssl-key`) and any other parameter is refused, so a URL that asks for TLS never connects without it. It keeps the same three tables in MySQL's dialect: the JSON columns are `LONGTEXT` holding the SDK's JSON byte for byte, never MySQL's `JSON` type (which reorders keys), and names compare as bytes (`utf8mb4_bin`), as they do in SQLite and Postgres.

`new PostgresStore($url = null, $username = null, $password = null, pdo: null, prefix: 'cronwatch_')` takes a `postgres://` or `postgresql://` URL (its query parameters, such as `sslmode`, go to libpq), a `pgsql:` DSN, or `DATABASE_URL`. It uses the SDK's tables and statements, so a process in any other language can share the database, and creates its tables under an advisory lock, so many processes can start at once.

Given a URL or DSN, the MySQL and Postgres stores open a connection of their own in autocommit mode, so a run recorded inside your transaction is recorded when it happens and stays recorded if that transaction rolls back. They reconnect once when the server has gone away. Given your `PDO`, they share it, transactions and all.

`prefix` names the tables (`cronwatch_jobs`, `cronwatch_runs`, `cronwatch_state`). Each store runs `CREATE TABLE IF NOT EXISTS` on first use; for a database user who may not create tables, make them once with `$store->init()` from a user who may, and wrap the store in `new Cronwatch\Store\Migrated($store)`, whose `init()` does nothing.

A store of your own implements `Cronwatch\Store\Store` (`init`, `upsertJob`, `getJob`, `listJobs`, `deleteJob`, `insertRun`, `updateRun`, `getRun`, `listRuns`, `lastRun`, `runningRuns`, `getState`, `setState`, `prune`, `close`), with epoch milliseconds for every time, and the conditional writes as interfaces of their own: `UpdatesRunIf`, `ComparesAndSetsState` and `DeletesRunIf`. They mean what the [TypeScript interface](/docs/stores/#writing-a-store) says. The conditional writes are what keep PHP-FPM workers, queue workers and cron scripts on one store from judging a run twice or losing each other's updates; see [two processes, one store](/docs/stores/#two-processes-one-store).

## Alerts

```php
use Cronwatch\Alert;
use Cronwatch\Alerts\Discord;
use Cronwatch\Alerts\Slack;
use Cronwatch\Alerts\Webhook;

$link = fn (Alert $alert) => "https://app.example.com/cronwatch/jobs/{$alert->job}";

$alerts = [
    new Slack(getenv('SLACK_WEBHOOK_URL'), link: $link),
    new Discord(getenv('DISCORD_WEBHOOK_URL')),
    new Webhook('https://hooks.example.com/cronwatch', secret: getenv('CRONWATCH_WEBHOOK_SECRET') ?: null),
    function (Alert $alert): void {
        if ($alert->type !== 'recovered') {
            pagerduty_trigger($alert->title, $alert->message);
        }
    },
];
```

Every alert goes to every channel, one after another. A channel that throws goes to `onError` as `alert channel <name>` and never stops the others; each request has a ten second deadline, so a hung webhook holds a check for at most that long. An alert is stored with the state that opens its condition before it is sent, so one whose process ends mid-send (a time limit, a deploy, a kill) is sent by a check after five minutes: once, or twice if a channel took it just before the process ended.

A channel implements `Cronwatch\Alerts\AlertChannel` (`name()` and `send(Alert $alert, ChannelContext $context)`, which throws when the alert went nowhere), or is any callable, which is named `custom`. A callable that takes two arguments gets the `ChannelContext` too, whose `onError()` reports a problem that did not stop the alert (one of several recipients refusing it, say).

### Email, SMS and error trackers

The SDK's provider channels are in `Cronwatch\Alerts` too, with no Composer package behind them (SES requests are signed with SigV4, so no AWS SDK):

```php
use Cronwatch\Alerts\{Resend, Postmark, Sendgrid, Mailgun, Ses, Twilio, Sentry, Honeybadger, Datadog, Rollbar, Bugsnag, NewRelic};

// Email. Each takes from, to (one address or a list), subjectPrefix and link.
new Resend(apiKey: getenv('RESEND_API_KEY'), from: 'CronWatch <alerts@example.com>', to: 'ops@example.com');
new Postmark(serverToken: getenv('POSTMARK_SERVER_TOKEN'), from: 'alerts@example.com', to: 'ops@example.com');
new Sendgrid(apiKey: getenv('SENDGRID_API_KEY'), from: 'alerts@example.com', to: 'ops@example.com');
new Mailgun(apiKey: getenv('MAILGUN_API_KEY'), domain: 'mg.example.com', region: 'eu', from: 'alerts@example.com', to: 'ops@example.com');
new Ses(region: 'us-east-1', accessKeyId: getenv('AWS_ACCESS_KEY_ID'), secretAccessKey: getenv('AWS_SECRET_ACCESS_KEY'),
    from: 'alerts@example.com', to: 'ops@example.com');

// SMS, one message per number. Recoveries are not texted unless recovered: true.
new Twilio(accountSid: getenv('TWILIO_ACCOUNT_SID'), authToken: getenv('TWILIO_AUTH_TOKEN'), from: '+15005550006', to: ['+15551110000']);

// Error trackers: one issue per job and alert type.
new Sentry(dsn: getenv('SENTRY_DSN'));
new Honeybadger(apiKey: getenv('HONEYBADGER_API_KEY'));
new Datadog(apiKey: getenv('DD_API_KEY'), site: 'datadoghq.eu', tags: ['env:prod']);
new Rollbar(accessToken: getenv('ROLLBAR_ACCESS_TOKEN'));
new Bugsnag(apiKey: getenv('BUGSNAG_API_KEY'));
new NewRelic(accountId: getenv('NEW_RELIC_ACCOUNT_ID'), apiKey: getenv('NEW_RELIC_LICENSE_KEY'));
```

The options are the SDK's, as named arguments:

| Option | Channels |
|---|---|
| `subjectPrefix` | the email channels |
| `messageStream` | Postmark |
| `region` | `'eu'` for SendGrid, Mailgun and New Relic; the AWS region for SES |
| `sessionToken`, `configurationSetName` | SES |
| `apiKeySid`, `apiKeySecret`, `messagingServiceSid`, `segments` | Twilio |
| `environment` | Sentry, Honeybadger, Rollbar |
| `release` | Sentry |
| `endpoint` | Honeybadger, Bugsnag |
| `site`, `tags`, `host` | Datadog |
| `releaseStage` | Bugsnag |
| `eventType` | New Relic |
| `recovered`, `link` | wherever the SDK has them |

A missing key, address or account throws `InvalidArgumentException` when the channel is made.

Each sends exactly the request the SDK's does: the same URL, headers and body, byte for byte (the package's tests replay the SDK's recorded requests), with the same idempotency key, event id or UUID for one alert, so a provider that deduplicates drops a resend whichever language sent it. A refused request throws `<Provider> <origin> answered <status>: <start of the body>`, never the URL's path, with the channel's keys cut out of the quoted body. No channel follows a redirect, so credentials never reach another address. Twilio texts its numbers one after another. [Alerts](/docs/alerts/#email-sms-and-error-trackers) describes what each one sends.

Every channel takes `http:`, an `Cronwatch\Alerts\Http` to send through (`post($url, $body, $headers, $timeoutMs)`), for a proxy or a test double. `Cronwatch\Alerts\Transport::set($http)` sets the one every channel given none uses.

A webhook takes `headers:` for headers of your own (`['Authorization' => 'Bearer ...']`), and with a `secret` signs its body with `X-CronWatch-Signature: sha256=<hex>`. Verifying it in PHP:

```php
$body = file_get_contents('php://input');
$expected = 'sha256=' . hash_hmac('sha256', $body, $secret);
$ok = hash_equals($expected, $_SERVER['HTTP_X_CRONWATCH_SIGNATURE'] ?? '');
```

### Processes that cannot send

A job can run somewhere that cannot reach Slack or a mail relay: a sandboxed worker, a script without the app's secrets. Give that process `deliver: 'check'`:

```php
$recorder = new Cronwatch(store: new PostgresStore(), deliver: 'check');
```

It still records and evaluates every run, but queues each alert in the store instead of sending it. The next check in a process that sends normally delivers it, with triage if that process has it. Both processes must use the same store. See [processes that cannot send](/docs/alerts/#processes-that-cannot-send).

## pg_cron

pg_cron runs jobs inside Postgres, where nothing can wrap them. `PgCron` reads what pg_cron records instead: on every check it reads `cron.job`, declares each job with its schedule, and copies new rows of `cron.job_run_details` in as runs, so a job that stops running is missed, a failed run alerts and a run that never ends is stuck.

```php
use Cronwatch\Sources\PgCron;
use Cronwatch\Store\PostgresStore;

$cw = new Cronwatch(
    store: new PostgresStore(getenv('DATABASE_URL')),
    sources: [new PgCron(getenv('DATABASE_URL'), prefix: 'db:')],
);
```

The first argument is a `postgres://` URL (a connection of its own), a `pdo_pgsql` `PDO`, or any object with `query(string $sql, array $params): array`. Settings are read from `pg_settings`, which never raises, so a role that may not read them never aborts your transaction. The options (`jobs`, `prefix`, `jobName`, `options`, `timezone`) and the rules for renamed jobs, runs cut off by a restart and history seen for the first time are the SDK's; see [Supabase and pg_cron](/docs/supabase/).

## Redaction

Before a run's output and error are stored, shown or sent anywhere, `redact` rewrites them. The default, `Cronwatch\Output::redactSecrets`, blanks values that look like secrets (secret-named pairs, credentials in URLs, authorization headers, private keys, JWTs, webhook URLs, and AWS, GitHub, Slack, Stripe, Google and API key formats), exactly what the SDK's default blanks. Redaction runs before the cap, so the cut never keeps the rest of a secret whose label it cut off. An `expect` rule is checked before redaction, so it still sees what was logged.

```php
use Cronwatch\Output;

new Cronwatch(redact: false);   // keep output as logged
new Cronwatch(redact: fn (string $text) => preg_replace('/\d{16}/', '[card]', Output::redactSecrets($text)));
```

A `redact` that throws, or returns something other than a string, is reported to `onError` (as `redact`) and the default is used for that text.

## Triage

```php
use Cronwatch\Triage\Anthropic;

$cw = new Cronwatch(store: $store, alerts: $alerts, triage: new Anthropic(context: 'A Slim app on Postgres, jobs run from crontab.'));
```

| Option | Default | |
|---|---|---|
| `model` | `'claude-opus-5'` | any current model id |
| `effort` | `'medium'` | `'low'`, `'medium'` or `'high'` |
| `maxTokens` | `800` | a diagnosis is a paragraph |
| `context` | | a sentence about the app, so advice is specific |
| `fallbacks` | `true` | route a policy refusal to Anthropic's default fallback model inside the same request. Turn off if your account or gateway rejects the beta |
| `apiKey` | `ANTHROPIC_API_KEY` | |
| `baseUrl` | `ANTHROPIC_BASE_URL`, else `https://api.anthropic.com` | |

It needs no Anthropic package: it sends the Messages API request the official client sends, itself. It runs only when an alert is sent (never per run, never for a recovery), and once per alert. PHP cannot abandon a request that hangs, so triage has 25 seconds, and when the answer is late or the request fails the alert goes out without a diagnosis and the failure goes to `onError`. What is sent is in [AI triage](/docs/triage/).

A triage of your own is any callable that takes a `Cronwatch\TriageContext` (`alert`, `recentRuns`, `signal`) and returns a string or null.

## API

`new Cronwatch(...)`:

| Option | Default | |
|---|---|---|
| `store` | in memory | a store |
| `alerts` | the console | a list of channels or callables. `[]` sends nothing |
| `triage` | | a callable returning a diagnosis |
| `sources` | | where runs this process does not wrap come from, such as [pg_cron](#pg-cron). Each is synced at the start of every check; one that throws is reported to `onError` and the check carries on |
| `cronSecret` | `CRON_SECRET` | the bearer the dashboard's check endpoint accepts beside the token, and the one `handler()` requires. `''` counts as unset; `false` means none on purpose |
| `retention` | `'30d'` | how long finished runs are kept. Each job's newest run is always kept |
| `defaults` | | `grace`, `timeout`, `timezone`, `failuresBeforeAlert` applied to every job that does not set its own |
| `redact` | secret patterns | a callable applied to output and errors; `false` keeps them as logged. See [Redaction](#redaction) |
| `deliver` | `'now'` | `'check'` queues alerts for another process's check to send |
| `onError` | PHP's error log | `fn (Throwable $error, string $where) => ...` for failures outside jobs: the store, a channel, triage |
| `now` | the system clock | a callable returning epoch milliseconds; for tests |

`$cw->job($name, $options)` takes `schedule` (five or six field cron, a nickname such as `'@hourly'`, or `'every 5m'`), `timezone` (IANA; PHP's default zone, `date.timezone`, when left out), `grace` (`'10m'`), `timeout` (`'1h'`), `maxDuration`, `budget` (`['metric' => ceiling]`), `expect` (a string, a `Pattern` or a callable), `failuresBeforeAlert` (1), `description` and `tags`, with the rules in the [API reference](/docs/api/). A name is 1 to 120 letters, digits, `.`, `_`, `:` or `-`, starting with a letter or digit. Bad options throw `InvalidArgumentException` when the job is declared.

The client:

| Method | |
|---|---|
| `job($name, $options)` | declare a job and get its handle: `run()`, `wrap()`, `handler()`, `start()`, `resume()` |
| `run($name, $fn, $options)` | run without keeping a handle |
| `check()` | find missed and stuck runs, send alerts, retry alerts no channel accepted, prune |
| `jobs()`, `jobsWithRuns($limit = 20)`, `jobSummary($name)` | summaries, without alerting |
| `runs($name, $limit = 50)`, `getRun($id)` | newest first; `limit` is 1 to 500 |
| `silence($name, '2h')`, `unsilence($name)` | stop alerts for a while; state keeps updating underneath. The silence ends on a whole millisecond, held at 2^53 - 1 ms however long it asks for |
| `forget($name)` | remove a job and its runs. A job still declared in code comes back: on its next run, or at the next check or dashboard read of a process that declares it |
| `resumeRun($name, $id)` | `job($name)->resume($id)` for a job declared in this process |
| `recordRun($run, evaluate: true)` | record a run that happened elsewhere, for a source; a metric that is not a finite number throws and nothing is recorded; returns the alerts it sent |
| `routes(...)` | the dashboard and JSON API |
| `definedJobs()` | the definitions declared in this process |
| `Cronwatch::current()` | the context of the run in progress in this process, or null |
| `close()` | close the store; called during a check, once the check ends |

There is no `start()` or `stop()`: a PHP process does not stay up between checks, so the check is a crontab line, a scheduler entry or a worker's own loop. A check called from inside a check (by a channel, a source or triage) throws `LogicException`.

## Sharing a database with the other languages

The SQLite and Postgres stores write the same three tables as `@cronwatch/sdk/sqlite` and `@cronwatch/sdk/postgres`, the Ruby gem's store, the Python package's and the Go, Rust, Elixir, Java and .NET ports' SQL stores: the same names, columns and indexes, epoch milliseconds in the time columns, and the same JSON in the JSON columns. The MySQL store keeps the same columns and values in MySQL's dialect, which the Go, Rust, Elixir, Java and .NET ports' MySQL stores write too; Node, Ruby and Python have no MySQL store. The package's tests share a SQLite file with the built SDK and check that each side reads what the other wrote, column by column. Create the tables from any side; the others find them and leave them alone. Use the same prefix everywhere.

Each process alerts on the jobs it runs, and any side's check sees every job in the store. One dashboard shows them all, and one MCP server reads it. Give each job a name only one side uses, and run one checker for the store.

The cron reader matches croner with two exceptions, both for schedules that never make sense: a date no month has (`0 0 30 2 *`) is a schedule that never fires, where croner gives up; and a one-time date in place of a cron expression (`2026-12-01T00:00:00`) is refused. Without a `timezone`, a schedule is read in PHP's default zone, where the SDK reads the process's `TZ`.

## Kept in step

The TypeScript SDK is the source of truth. Its build generates cases (duration parsing, schedules across daylight saving, sequences of runs and checks with the alerts and state they must produce, alert titles and messages, each channel's requests, triage requests, pg_cron reads, stats and health) into `conformance/` in the repository, and the PHP package's tests replay every one, as the Ruby gem's and the Python package's do. The dashboard is checked against the SDK's routes too: every page, header and JSON body, byte for byte. A change of behaviour lands in TypeScript first, the cases are regenerated, and the port is fixed until they pass. Where they disagree, the port is wrong: [open an issue](https://github.com/phillips-jon/cronwatch/issues).
