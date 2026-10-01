---
title: Java
description: dev.cronwatch:cronwatch in a JVM service: one client, jobs run in the calling thread, the check, the SQL store over your DataSource, alert channels, Claude triage, pg_cron, the dashboard and job handlers on the JDK's server, a servlet container or Spring, a crontab's check with CronwatchCli, and sharing one database with the other languages.
order: 3.95
group: Java
---

# Java

`dev.cronwatch:cronwatch` is a port of `@cronwatch/sdk`, not a new design. It decides missed, failed, stuck, slow and over budget by the same rules, sends the same alert text, and writes the same rows, so a Java process can share one database with a Node, Ruby, Python, PHP, Go, Rust, Elixir or .NET process and the [MCP server](/docs/mcp/) works against any of them. This page covers the library itself: a `main` a crontab runs, a service on the JDK's own HTTP server or in a servlet container. The Spring Boot starter (`@Scheduled` and ShedLock), Quartz and JobRunr have a page of their own: [Java schedulers](/docs/java-schedulers/).

```xml
<!-- pom.xml -->
<dependency>
  <groupId>dev.cronwatch</groupId>
  <artifactId>cronwatch</artifactId>
  <version>{{JAVA_VERSION}}</version>
</dependency>
```

```kotlin
// build.gradle.kts
implementation("dev.cronwatch:cronwatch:{{JAVA_VERSION}}")
```

Java 21 or newer. The core depends on nothing: cron expressions are read by a port of [croner](https://github.com/hexagon/croner), the parser the SDK uses, so every port agrees on every fire time; zones come from the JDK's own copy of the IANA database; the alert channels and Claude triage post over the JDK's `java.net.http.HttpClient`. It is a named module, `dev.cronwatch`. The rest comes from your app, or from an artifact of its own:

| Artifact or dependency | For |
|---|---|
| your JDBC driver: `org.xerial:sqlite-jdbc`, `org.postgresql:postgresql`, `com.mysql:mysql-connector-j` or `org.mariadb.jdbc:mariadb-java-client` | `SqlStore` over your `DataSource`, and the pg_cron source; none is a dependency of CronWatch |
| `dev.cronwatch:cronwatch-servlet` | the dashboard and a job's handler in a servlet container: Tomcat 10.1, Jetty 12, any Jakarta EE 10 or 11 server |
| `dev.cronwatch:cronwatch-spring-boot-starter` | Spring Boot 3.5 and 4: the client from `cronwatch.*`, every `@Scheduled` method watched, ShedLock, the dashboard on Spring MVC or WebFlux; see [Java schedulers](/docs/java-schedulers/#spring-boot) |
| `dev.cronwatch:cronwatch-quartz` | Quartz 2.5; see [Java schedulers](/docs/java-schedulers/#quartz) |
| `dev.cronwatch:cronwatch-jobrunr` | JobRunr 8; see [Java schedulers](/docs/java-schedulers/#jobrunr) |
| SLF4J, Micrometer's `context-propagation` | used when your app has them: the run's ids in the MDC, and the current run carried across threads |

## Create one client

One client per app, kept where the app keeps its `DataSource`, and closed when the app stops:

```java
var dataSource = new org.postgresql.ds.PGSimpleDataSource();
dataSource.setUrl("jdbc:postgresql://localhost/app");

Cronwatch cw = Cronwatch.builder()
    .store(SqlStore.postgres(dataSource))            // default: a MemoryStore
    .alert(Slack.webhook(System.getenv("SLACK_WEBHOOK_URL")))
    .retention("30d")
    .build();
cw.start();                                          // check every minute, in a long-running service
```

Every option has the SDK's default, and `build()` checks them, so a bad option fails at startup with the SDK's message, as a `CronwatchException`. With no options it keeps everything in memory and writes alerts to standard error. `close()` stops the check, waits up to five seconds for a check and sends in flight, and closes the store; a servlet container or a Spring context calls it when the app stops, so no thread of the client's holds the app's class loader.

The client's own work (recording a run, sending alerts, checking) runs on virtual threads of its own, so an interrupt of your thread never cuts a write in half. Everything on `Cronwatch`, `Job` and a run's context is safe to use from any thread.

## Declare and run a job

Declare each job once, at startup, and keep its handle:

```java
Job nightly = cw.job("nightly-report", JobOptions.builder()
    .schedule("0 2 * * *").timezone("UTC")
    .grace("15m").timeout(Duration.ofMinutes(30))
    .expect("Report written").budget("cost", 2));

nightly.run(job -> {
  Path path = reports.build();                        // an IOException thrown here is thrown from run()
  job.log("Report written: " + path);                 // kept with the run, shown in alerts
  job.metric("cost", 1.2);                            // watched against budgets and baselines
});

Path path = nightly.call(job -> reports.build());     // call() returns what the function returns
```

`run` takes a function that returns nothing and `call` one that returns a value. Each runs the function in the calling thread, where your transaction, MDC and security context live, as a recorded run. Anything the function throws, checked or not, fails the run and is thrown again as it came, its type and stack intact, so your own error handling sees exactly what it would have without CronWatch; the function types are generic in what they throw, so `run` declares exactly the checked exceptions your lambda throws. The store failing never stops a job: its failures go to the error handler (`onError`, by default `System.Logger` named `dev.cronwatch`), and the job's own outcome is what you get.

A name is 1 to 120 letters, digits, `.`, `_`, `:` or `-`, starting with a letter or digit. `cw.run(name, fn)` and `cw.call(name, fn)` declare a name they have not seen, for a job run once. `JobOptions` keeps its fields in the order you set them, so the stored definition is the JSON a Node process writes for the same options in the same order. Durations take the SDK's text (`"15m"`, `"1h30m"`, stored as written), a `java.time.Duration` or milliseconds.

A `String` that `call`'s function returns is the run's output when nothing was logged, and what `expect` checks. An HTTP answer of 400 or more (a `java.net.http.HttpResponse`, or Spring's `ResponseEntity`) fails the run with `HTTP <status> <reason>`, so a job that calls an API and returns its answer fails when the API does. The run keeps the last 16 KB of output.

A failed run's error is written as the SDK writes a JavaScript error: the exception's simple name and message (`IOException: disk full`), then up to five frames of its stack, each `com.example.Reports.build (Reports.java:42)`. Causes are not written.

### Threads and the timeout

`Cronwatch.current()` answers the run the calling thread is in, so code deep in a call chain can log to it. A thread the job starts has none of its own: `job.wrap(runnable)` (or a `Callable`) carries it across, and so does Micrometer's context propagation (Spring's `ContextPropagatingTaskDecorator`, Reactor's automatic propagation) when it is on the class path. With SLF4J on the class path, `cronwatch_job` and `cronwatch_run` are in the MDC during a run.

A job's timeout (an hour by default) sets `job.cancelled()` and calls what `job.onCancel(...)` registered, the SDK's abort signal; nothing is stopped. `RunOptions.interruptingAtTimeout()` also interrupts the running thread at the timeout, and a run that then ends by throwing is recorded as timed out, so the stuck alert goes out at once:

```java
Job sync = cw.job("sync", JobOptions.builder().timeout("5m"));
sync.run(RunOptions.interruptingAtTimeout(), job -> {
  while (!job.cancelled()) {
    Thread.sleep(1000);                               // interrupted at the timeout
  }
});
```

A run that goes on past its timeout without either is marked stuck by the next check; if it finishes later, a late failure is written without a second alert and a late success closes the stuck alert with a recovery.

When the JVM begins to stop (`System.exit`, a `SIGTERM`), a shutdown hook records every run still open in the process as failed (`Shutdown: the JVM stopped while the run was in progress`), rather than leave it to be reported stuck later. `noShutdownHook()` on the builder leaves it out.

## Run the check

A job that never starts cannot report itself, so something has to look. `cw.start()` checks every minute, the first a second after it is called, for a long-running service; `start("5m")` or `start(Duration)` sets the interval (five seconds at least), and `stop()` ends it. Where another process checks, call `check()` there:

```java
CheckResult result = cw.check();   // checkedAt, jobs, alerts, pruned
```

One process checking is enough; every instance of a service checking is harmless, since a check judges each run once. Calls at the same time share one check. In a Spring Boot app the starter runs the check for you, once per cluster under ShedLock or Quartz; see [Java schedulers](/docs/java-schedulers/#the-check-1).

### From a crontab

A program a crontab runs exits when it is done, so nothing inside it notices the run that never happened. Add a second crontab line that checks, on a store both reach. The check needs the same store and channels as the job, which only your app knows, so it is a `main` of your own that hands `CronwatchCli` the factory for your client:

```java
public final class Nightly {
  /** The client both lines build: the same store, so the check sees the job's runs. */
  public static Cronwatch cronwatch() {
    var dataSource = new org.sqlite.SQLiteDataSource();
    dataSource.setUrl("jdbc:sqlite:/var/lib/app/cronwatch.db");
    Cronwatch cw = Cronwatch.builder().store(SqlStore.sqlite(dataSource)).build();
    cw.job("nightly-report", JobOptions.builder().schedule("0 2 * * *").grace("15m"));
    return cw;
  }

  public static void main(String[] args) {
    try (Cronwatch cw = cronwatch()) {
      cw.run("nightly-report", job -> reports.build(job));
    } catch (Exception e) {
      System.exit(1);                                 // a failed run exits non-zero, so cron mails it
    }
  }
}

public final class CronwatchMain {
  public static void main(String[] args) {
    CronwatchCli.main(Nightly::cronwatch, args);
  }
}
```

```
# m  h  dom mon dow  command
0    2  *   *   *    java -cp app.jar com.example.Nightly
*/5  *  *   *   *    java -cp app.jar com.example.CronwatchMain check
```

The job is declared in the factory too, so the check knows its schedule before its first run. `check` makes the client, runs one check, prints what it did (`cronwatch: checked 3 jobs, sent 1 alert`), closes the client, and exits 1 when the check fails (2 for a command it does not know), so cron mails it. Code already running in an app calls `CronwatchCli.run`, which answers the status and never ends the JVM. [`examples/crontab`](https://github.com/phillips-jon/cronwatch/tree/main/packages/java/examples/crontab) in the repository is this program on SQLite, with a test that runs both lines on one file.

## The dashboard

`cw.routes()` is the dashboard and JSON API, the same pages and endpoints as the TypeScript routes, byte for byte: the board's counts by health, a timeline of the last day with a lane per job, the table of every job, and for each job its last seven days, runs and definition, all drawn on the server with no script. It is framework-free (`Routes.handle` takes a `dev.cronwatch.web.Request` and answers a `Response`), and served by an adapter. On the JDK's own server:

```java
HttpServer server = HttpServer.create(new InetSocketAddress(8080), 0);
server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());   // the routes read the store
WebServer.mount(server, "/cronwatch", cw.routes(RoutesOptions.builder()
    .token(System.getenv("CRONWATCH_TOKEN"))
    .build()));
server.start();
```

In a servlet container, `dev.cronwatch:cronwatch-servlet` has `CronwatchFilter`, which answers the requests under its path (`/cronwatch` by default, within the web app's context) and passes every other one down the chain, so it can sit ahead of your own servlets and security:

```java
FilterRegistration.Dynamic filter =
    servletContext.addFilter("cronwatch", new CronwatchFilter(cw.routes(), "/cronwatch"));
filter.addMappingForUrlPatterns(null, false, "/cronwatch", "/cronwatch/*");
```

In a Spring Boot app, the starter registers it on Spring MVC, or a `WebFilter` on WebFlux, from `cronwatch.web.*`, ahead of Spring Security's filter chain since the dashboard checks its own token; see [Java schedulers](/docs/java-schedulers/#the-dashboard-in-spring).

`RoutesOptions`:

- `token(...)`: the token. Left out, it is `CRONWATCH_TOKEN`. Send it as `Authorization: Bearer <token>`, or open the dashboard once with `?token=<token>` and a cookie holds a digest of it. Without a token, in development, the dashboard makes one and prints a sign-in link to standard output on its first request (naming the host only when `origin` is set or the request came to a loopback host); anywhere else it answers 503. The environment is `CRONWATCH_ENV`, else `APP_ENV` (else the builder's `environment(...)`, which the starter sets from the active profile), and `development`, `dev`, `local`, `test` and `testing` count as development.
- `noToken()`: serve it to anyone, for a mount behind your own auth.
- `origin("https://app.example.com")`: the public origin, pinned whatever a request says, for the cross-site check on writes, the cookie's `Secure` flag, redirects and the sign-in line.
- `trustProxy()`: take the origin from the first `X-Forwarded-Proto` and `X-Forwarded-Host`. Only behind a proxy that sets or overwrites both.
- `basePath(...)`: where it is mounted, when the adapter cannot tell; the JDK server's context and the servlet filter's path say so already.

A request body past 1 MiB is answered 413. The token rules, cookie, cross-site rule and every endpoint are the SDK's; see [Dashboard and API](/docs/dashboard/). `/api/check` also accepts the client's cron secret as a bearer, so an outside cron can run the check over HTTP. The dashboard is installable as a web app, with its manifest, icons and service worker under the mount point; see [Install it as an app](/docs/dashboard/#install-it-as-an-app). Tomcat, Jetty and Spring Security refuse an encoded slash (`%2F`) in a path by default, so a job whose name holds a `/` is reached through the dashboard behind them only if the app allows it; the JDK's server passes it through.

## Jobs a URL starts

Some platforms run scheduled work by calling a URL: a Kubernetes CronJob running `curl`, Cloud Run jobs behind Cloud Scheduler, Render, Fly.io, an outside cron service. `job.handler(fn)` is that endpoint: each request carrying `Authorization: Bearer <secret>` runs the function in the request's thread as a recorded run (trigger `handler`), answered with JSON saying how the run went.

```java
Job nightly = cw.job("nightly-report", JobOptions.builder().schedule("0 2 * * *"));
Handler handler = nightly.handler((job, request) -> {
  reports.build(job);
  job.log("Report written");
  return null;                                        // or a Response of your own
});
WebServer.mount(server, "/cron/nightly", handler);    // or new CronwatchServlet(handler) in a container
```

The secret is `HandlerOptions.builder().secret(...)`, else the client's cron secret (`cronSecret(...)` on the builder, `CRON_SECRET` by default), compared in constant time; `""` counts as unset. A wrong or missing bearer is answered 401 and runs nothing. With no secret at all, outside development, the handler answers 503 and reports it once to the error handler, rather than let anyone on the internet run the job; `noSecret()` (or the client's `noCronSecret()`) opts out on purpose, for an endpoint your platform already protects.

A run is answered 200 or 500 with `{"ok","job","run","status","durationMs"}`, and the error's first line as `"error"` for a caller who sent the secret. A `String` the function returns is the run's output when nothing was logged; a `Response` it returns is the answer itself, and a status of 400 or more fails the run.

## Stores

`MemoryStore` is the default, for tests and trying it out. Nothing survives a restart, so a miss cannot be noticed across one, and each process has its own. When the environment is production (`CRONWATCH_ENV` or `APP_ENV` set to `production` or `prod`), the client warns once that it is using it.

`SqlStore` keeps the same three tables as the SDK's SQL stores in your database, through your `DataSource`:

| Factory | |
|---|---|
| `SqlStore.sqlite(dataSource)` | xerial's `sqlite-jdbc`. The store takes one connection and keeps it, in WAL mode with a `busy_timeout` of 5000, as the SDK's store holds one; a pool of one connection leaves your app none |
| `SqlStore.postgres(dataSource)` | `JSONB` for the JSON; tables made under an advisory lock, so many processes can start at once |
| `SqlStore.mysql(dataSource)` | MySQL 8.0.13 or newer, or MariaDB 10.6 or newer |
| `SqlStore.of(dataSource)` | the dialect picked from the driver |

```java
Cronwatch cw = Cronwatch.builder().store(SqlStore.postgres(dataSource).prefix("app_cron_")).build();
```

The tables (`cronwatch_jobs`, `cronwatch_runs`, `cronwatch_state`) are made on the client's first use, byte for byte as the SDK makes them. `prefix(...)` names them: lowercase letters, digits and underscores, not starting with a digit, at most 47 characters. The store's writes never join a transaction your code has open: on Postgres and MySQL each statement takes a connection of its own from the data source, in autocommit, so a run recorded inside a transaction that rolls back stays recorded. Give it a plain data source, not one that hands out your transaction's connection (Spring's `TransactionAwareDataSourceProxy`).

A store of your own implements `dev.cronwatch.store.Store`: `init`, `upsertJob`, `getJob`, `listJobs`, `deleteJob`, `insertRun`, `updateRun`, `getRun`, `listRuns`, `lastRun`, `runningRuns`, `getState`, `setState`, `prune` and `close`, with epoch milliseconds for every time. Three default methods are what keep processes sharing a store from judging a run twice or losing each other's updates: `updateRunIf`, `compareAndSetState` and `deleteRunIf` (which takes back an attempt a scheduler gave back without failing; see [Java schedulers](/docs/java-schedulers/#retries)). They mean what the [TypeScript interface](/docs/stores/#writing-a-store) says. `dev.cronwatch.storetest` is the contract the built-in stores pass, from any test framework:

```java
StoreContract.run(new MyStore());
```

`StoreReplay` replays the SDK's recorded store cases (`conformance/store.json`, which your test reads), and `FinishOnce` runs several clients over one database to hold a run to being recorded and judged once.

## Alerts

`Console` is the default channel: a recovery to standard output and anything else to standard error, where a crontab's mail and a container's log collector read them. The first `alert(...)` on the builder replaces it; `alerts(List.of())` sends nothing. The SDK's fifteen channels are in `dev.cronwatch.alerts`, each made from its options, whose `build()` refuses what the SDK refuses:

```java
Cronwatch cw = Cronwatch.builder()
    .alert(Slack.webhook(System.getenv("SLACK_WEBHOOK_URL")))
    .alert(Discord.webhook(System.getenv("DISCORD_WEBHOOK_URL")))
    .alert(Webhook.channel(WebhookOptions.builder()
        .url("https://hooks.example.com/cronwatch")
        .secret(System.getenv("CRONWATCH_WEBHOOK_SECRET"))
        .build()))
    .alert(Channel.of("pagerduty", (alert, ctx) -> {
      if (!alert.type().equals(AlertType.RECOVERED)) pagerDuty.trigger(alert.title(), alert.message());
    }))
    .build();
```

Every alert goes to every channel at once, each on a virtual thread of its own with 15 seconds to finish; a send past its time is interrupted and counted as failed, and a channel that fails goes to the error handler (as `alert channel <name>`) and never holds up the others. `Channel.of(name, fn)` wraps a function of the alert and a `ChannelContext`, and throws when the alert went nowhere; a channel of your own implements `Channel` (`name()` and `send(alert, context)`).

### Email, SMS and error trackers

```java
// Email. Each takes the email options: from, to, subjectPrefix, link.
Resend.channel(ResendOptions.builder().apiKey(System.getenv("RESEND_API_KEY"))
    .from("CronWatch <alerts@example.com>").to("ops@example.com").build());
Postmark.channel(PostmarkOptions.builder().serverToken(System.getenv("POSTMARK_SERVER_TOKEN"))
    .from("CronWatch <alerts@example.com>").to("ops@example.com").build());
SendGrid.channel(SendGridOptions.builder().apiKey(System.getenv("SENDGRID_API_KEY"))
    .from("CronWatch <alerts@example.com>").to("ops@example.com").build());
Mailgun.channel(MailgunOptions.builder().apiKey(System.getenv("MAILGUN_API_KEY"))
    .domain("mg.example.com").region("eu")
    .from("CronWatch <alerts@example.com>").to("ops@example.com").build());
Ses.channel(SesOptions.builder().region("us-east-1")
    .accessKeyId(System.getenv("AWS_ACCESS_KEY_ID"))
    .secretAccessKey(System.getenv("AWS_SECRET_ACCESS_KEY"))
    .from("CronWatch <alerts@example.com>").to("ops@example.com").build());

// SMS, one message per number, all at once. recovered(true) texts recoveries too.
Twilio.channel(TwilioOptions.builder()
    .accountSid(System.getenv("TWILIO_ACCOUNT_SID"))
    .authToken(System.getenv("TWILIO_AUTH_TOKEN"))
    .from("+15005550006").to("+15551110000").build());

// Error trackers: one issue per job and alert type.
Sentry.channel(SentryOptions.builder().dsn(System.getenv("SENTRY_DSN")).build());
Honeybadger.channel(HoneybadgerOptions.builder().apiKey(System.getenv("HONEYBADGER_API_KEY")).build());
Datadog.channel(DatadogOptions.builder().apiKey(System.getenv("DD_API_KEY"))
    .site("datadoghq.eu").tags("env:prod").build());
Rollbar.channel(RollbarOptions.builder().accessToken(System.getenv("ROLLBAR_ACCESS_TOKEN")).build());
Bugsnag.channel(BugsnagOptions.builder().apiKey(System.getenv("BUGSNAG_API_KEY")).build());
NewRelic.channel(NewRelicOptions.builder().accountId(1234567)
    .apiKey(System.getenv("NEW_RELIC_LICENSE_KEY")).build());
```

The options are the SDK's in camelCase: `subjectPrefix` and `link` among the email options; `messageStream` (Postmark); `region` (`"eu"` for SendGrid, Mailgun and New Relic, the AWS region for SES); `sessionToken` and `configurationSetName` (SES); `apiKeySid`, `apiKeySecret`, `messagingServiceSid` and `segments` (Twilio, 1 to 10, default 3); `environment` (Sentry, Honeybadger and Rollbar, `"production"` by default); `release` (Sentry); `header(name, value)` (the webhook, extra request headers in the order sent); `endpoint` (Honeybadger, Bugsnag); `host` (Datadog); `releaseStage` (Bugsnag); `eventType` (New Relic); and `recovered` and `link` wherever the SDK has them, with the SDK's defaults (`recovered(false)` leaves a Sentry or Rollbar channel's recoveries out). No channel's `toString()` prints a credential.

Each sends exactly the request the SDK's does: the same URL, headers and body, byte for byte (the package's tests replay the SDK's recorded requests), with the same idempotency key, event id or UUID for one alert, so a provider that deduplicates drops a resend whichever language sent it. SES is signed with SigV4, with no AWS SDK. Each request has one ten second deadline for the whole request, reads at most 1 MiB of the answer, follows no redirect (so credentials never reach another address), and always verifies TLS. A refused request names only the URL's origin, never its path, with the channel's keys cut out. The requests go through the client's `Transport`, by default a `JdkTransport` over one `HttpClient` the client makes on its first send and closes with itself; `transport(...)` on the builder, or on one channel's or triage's options, takes one of your own, for a proxy, your own trust store or another HTTP client. [Alerts](/docs/alerts/#email-sms-and-error-trackers) describes what each one sends.

A webhook signs its body with `X-CronWatch-Signature: sha256=<hex>`. `Webhook.signature(secret, body)` is that hex, for a receiver in Java; compare it with `MessageDigest.isEqual`.

### Processes that cannot send

A job can run somewhere that cannot reach Slack or a mail relay: a sandboxed worker, a batch host without the app's secrets. Give that client `deliver(Deliver.AT_CHECK)`:

```java
Cronwatch cw = Cronwatch.builder().store(store).deliver(Deliver.AT_CHECK).build();
```

It still records and evaluates every run, but queues each alert in the store instead of sending it. The next check in a client that sends normally delivers it, with triage if that client has it. Both must use the same store. See [processes that cannot send](/docs/alerts/#processes-that-cannot-send).

## pg_cron

pg_cron runs jobs inside Postgres, where nothing can wrap them. `PgCron.source` reads what pg_cron records instead: on every check it reads `cron.job`, declares each job with its schedule, and copies new rows of `cron.job_run_details` in as runs, so a job that stops running is missed, a failed run alerts and a run that never ends is stuck.

```java
Cronwatch cw = Cronwatch.builder()
    .store(SqlStore.postgres(dataSource))
    .source(PgCron.source(dataSource, PgCronOptions.builder()
        .prefix("db:")
        .options(JobOptions.builder().grace("5m"))
        .build()))
    .build();
cw.start();
```

It reads through a data source on the database pg_cron runs in (its `cron.database_name`), each query on a connection of its own in autocommit. Its options: `jobs`, `jobIds` and `pick` to choose jobs; `prefix`, `jobName`, and `options` (job options for every job, or a function answering them per job; the schedule and zone always come from pg_cron); and `timezone` (by default the server's `cron.timezone`, else UTC). The rules for renamed jobs, runs cut off by a restart and history seen for the first time are the SDK's; see [Supabase and pg_cron](/docs/supabase/).

## Redaction

Before a run's output and error are stored, shown or sent anywhere, they are redacted. The default blanks values that look like secrets (secret-named pairs, credentials in URLs, authorization headers, private keys, JWTs, webhook URLs, and AWS, GitHub, Slack, Stripe, Google and API key formats), exactly what the SDK's default blanks: the patterns are the SDK's, run by an engine with JavaScript's semantics, so every case the SDK's tests hold gives the same bytes. Redaction runs before the 16 KB cap, so the cut never keeps the rest of a secret whose label it cut off. An `expect` rule is checked before redaction, so it still sees what was logged.

```java
Cronwatch.builder().noRedaction();                                   // keep output as logged
Cronwatch.builder().redact(text -> text.replaceAll("\\b\\d{16}\\b", "[card]"));
```

A function given to `redact(...)` replaces the default; one that throws or answers null is reported and the default is used.

`expect` takes the text the output must contain; `expectMatch(source, flags)` takes a JavaScript regular expression, stored as `matches /source/flags` and run by the same engine, so it reads as the SDK reads it; `expectThat(predicate)` takes a function of the output (a throw in it fails the run). A `java.util.regex.Pattern` is not taken: it reads a pattern differently, and another port could not run what it stored. A stored pattern that runs past fifty million steps (one that backtracks over an output it does not match) fails the run.

## Triage

```java
Cronwatch cw = Cronwatch.builder()
    .alert(Slack.webhook(System.getenv("SLACK_WEBHOOK_URL")))
    .triage(Anthropic.triage(AnthropicOptions.builder()
        .context("A Spring Boot service on Kubernetes with a Postgres database.")
        .build()))
    .build();
```

`AnthropicOptions`:

| Option | Default | |
|---|---|---|
| `model` | `"claude-opus-5"` | any current model id |
| `effort` | `"medium"` | `"low"`, `"medium"` or `"high"` |
| `maxTokens` | 800 | a diagnosis is a paragraph |
| `context` | | a sentence about the app, so advice is specific |
| `noFallbacks()` | fallbacks on | stops routing a policy refusal to Anthropic's default fallback model inside the same request, if your account or gateway rejects the beta |
| `apiKey` | `ANTHROPIC_API_KEY`, read when triage runs | |
| `baseUrl` | `ANTHROPIC_BASE_URL`, else `https://api.anthropic.com` | |
| `transport` | the client's | as for the channels |

There is no Anthropic client to add: the Messages API is one POST, and it sends the request the SDK's official client sends. It runs only when an alert is sent (never per run, never for a recovery), once per alert, with one attempt and no retries. The client waits 25 seconds for it and the request gives up first, so the alert goes out without a diagnosis rather than late, and the failure is reported to the error handler. What is sent is in [AI triage](/docs/triage/). A triage of your own implements `Triage`: it is given the alert and the job's newest runs, and answers a diagnosis, or null for none.

## API

The builder's options:

| Option | Default | |
|---|---|---|
| `store` | `MemoryStore` | |
| `alert`, `alerts` | `Console` | channels. `alerts(List.of())` sends nothing |
| `triage` | | `Anthropic.triage(...)`, or a `Triage` of your own |
| `source` | | where runs this client does not wrap come from, such as [pg_cron](#pg-cron). Each is synced at the start of every check; one that fails is reported and the check carries on |
| `cronSecret`, `noCronSecret()` | `$CRON_SECRET` | the bearer job handlers take and the dashboard's check endpoint accepts beside the token |
| `retention` | `"30d"` | how long finished runs are kept. Each job's newest run is always kept |
| `defaults` | | `grace`, `timeout`, `timezone` and `failuresBeforeAlert` for every job that does not set its own; any other option is refused |
| `redact`, `noRedaction()` | secret patterns | see [Redaction](#redaction) |
| `deliver` | `Deliver.NOW` | `Deliver.AT_CHECK` queues alerts for another client's check to send |
| `transport` | a `JdkTransport` | for every channel and triage without one of their own |
| `onError` | `System.Logger` `dev.cronwatch` | an `ErrorHandler` of the error and where, for failures outside jobs: the store, a channel, triage |
| `environment` | | the environment when neither `CRONWATCH_ENV` nor `APP_ENV` is set |
| `noShutdownHook()` | the hook on | see [Threads and the timeout](#threads-and-the-timeout) |
| `clock` | the system clock | epoch milliseconds; for tests |

A job's options, on `JobOptions.builder()`: `schedule` (five or six field cron, a nickname such as `"@hourly"`, or `"every 5m"`), `timezone` (IANA; the JVM's zone by default), `grace` (`"10m"`), `timeout` (`"1h"`), `maxDuration`, `budget` (a metric and its ceiling, or a map of them), `expect`, `expectMatch`, `expectThat`, `failuresBeforeAlert` (1), `description` and `tags`, with the rules in the [TypeScript API reference](/docs/api/).

| Method | |
|---|---|
| `job(name, options)` | declare a job and get its handle |
| `job.run(fn)`, `job.call(fn)`, and with `RunOptions` | run as a recorded run; `RunOptions.trigger`, `interruptingAtTimeout` and `discardWhen` |
| `Cronwatch.current()`, `log`, `metric`, `cancelled`, `onCancel`, `wrap` | the run in progress, on its `JobContext` |
| `check()` | find missed and stuck runs, send alerts, retry alerts no channel accepted, prune |
| `start()`, `start(every)`, `stop()` | check on an interval |
| `jobs()`, `jobsWithRuns(limit)`, `jobSummary(name)` | summaries, without alerting |
| `runs(name, limit)`, `getRun(id)` | newest first; `limit` is held to 1 to 500 |
| `silence(name, duration)`, `unsilence(name)` | stop alerts for a while; state keeps updating underneath |
| `forget(name)` | remove a job and its runs |
| `job.start(options)`, `job.resume(id)`, `resumeRun(name, id)` | runs that span calls |
| `job.open(options)` | a run seen from outside the function, for a scheduler integration: an `ObservedRun` to close or take back |
| `recordRun(run)` | record a run that happened elsewhere, for a source (its id 1 to 200 characters, as `start` takes); answers the alerts it sent |
| `syncJob(name)` | write a declaration to the store now, unless it already holds it |
| `definedJobs()` | the jobs declared in this process |
| `routes()`, `job.handler(fn)` | the dashboard and a job's handler |
| `close()` | stop the check and close the store |

`CronwatchException` has a `kind()`: `INVALID` (an option, name, schedule or run id the SDK refuses, with its message), `STORE` (the store's own exception as the cause) and `OTHER`. Reads (`jobs()`, `jobSummary()`, `runs()`) and `check()` throw it when the store fails; `run`, `start`, `flush` and `finish` never do.

## Runs that span calls

A run is normally one call. Work that starts in one place and ends in another (a job that hands work to a queue, a webhook that reports completion later) can be one run too: `job.start` records it as running and answers a `RunHandle`, and `finish` on that handle, or on one from `resumeRun` in another process, ends it.

```java
RunHandle run = ingest.start(StartOptions.id("batch-42"));   // records a running run
run.log("fetched 1,200 rows");
run.flush();                                                  // appends what was logged so far
// later, perhaps in another process:
RunHandle again = cw.resumeRun("import", "batch-42");
again.finish();                                               // or again.fail(exception)
```

`StartOptions.id` takes your own stable id, 1 to 200 characters: a start with an id already recorded for this job records nothing and answers a handle on that run, and one recorded for another job is an error, as is an id starting `pgcron:`. The store never fails out of a handle: a failure goes to the error handler, and a finish the store failed leaves the handle active, its lines kept, so it can be called again. A run is judged once however many processes finish it: only the process whose conditional write lands evaluates it. A run that is never finished is marked stuck by the first check after the job's `timeout`, so set it to cover the whole span.

## Sharing a database with the other languages

`SqlStore` writes the same three tables as `@cronwatch/sdk/sqlite` and `@cronwatch/sdk/postgres`, the Ruby gem, and the Python, PHP, Go, Rust, Elixir and .NET stores (the MySQL tables are the PHP, Go, Rust, Elixir and .NET ports'): the same names, columns and indexes, epoch milliseconds in the time columns, and the same JSON in the JSON columns, byte for byte, keys in the SDK's order. The package's tests share a SQLite file with the built SDK, and have a Node client and a Java client take turns on one job's state. Create the tables from any side; the others find them and leave them alone. Use the same prefix everywhere.

Each process alerts on the jobs it runs, and any side's check sees every job in the store. One dashboard shows them all, and one MCP server reads it. Give each job a name only one side uses.

## Kept in step

The TypeScript SDK is the source of truth. Its build generates cases (duration parsing, schedules across daylight saving, sequences of runs and checks with the alerts and state they must produce, alert titles and messages, redaction, each channel's requests, stats and health) into `conformance/` in the repository, and the Java tests replay every one, as the Ruby gem's and the Python, PHP, Go, Rust, Elixir and .NET packages' do; the dashboard is checked against the SDK's pages byte for byte, straight into the routes and through the JDK's server, Jetty 12 (the servlet filter), and Spring MVC on Tomcat and WebFlux on Netty (the starter). Cron parsing is also checked against croner itself on thousands of generated expressions. A change of behaviour lands in TypeScript first, the cases are regenerated, and the port is fixed until they pass. Where they disagree, the port is wrong: [open an issue](https://github.com/phillips-jon/cronwatch/issues).
