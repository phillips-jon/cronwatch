# cronwatch for Java

Cron and scheduled-job monitoring that lives inside your JVM service. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make. This is the library behind [cronwatch.dev](https://cronwatch.dev).

This is the Java port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk): the same rules, the same alert text and the same stored rows, so a Java process and a Node, Ruby, Python, PHP, Go, Rust or Elixir process can share one database, and every port reads the tables the others write. It is built in phases ([DESIGN.md](DESIGN.md) has the plan and how each part works). Phase 1 has the core: jobs, runs in the calling thread, runs that span calls, checks, silences, sources, deferred delivery and the triage hook, the current run across threads, the shutdown hook, the memory store, and the SQL store over JDBC on SQLite. Phase 2 adds the SQL store on Postgres, MySQL and MariaDB, the SDK's fifteen alert channels, Claude triage and the pg_cron source; the dashboard, a job's handler and the servlet and Spring Boot adapters in phase 3; the `@Scheduled`, ShedLock and Quartz integrations in phase 4.

It is not on Maven Central yet. The first release will be `dev.cronwatch:cronwatch`.

## Install

Java 21 or newer. The core, `dev.cronwatch:cronwatch`, depends on nothing: cron expressions are read by a port of [croner](https://github.com/hexagon/croner), the parser the SDK uses, so every port agrees on every fire time; zones come from the JDK's own copy of the IANA database; JSON, the JavaScript regular expressions a stored `expect` pattern holds, and secret redaction are the port's own. The SQL store takes the app's `javax.sql.DataSource` and driver, as a normal dependency of your app: xerial's `org.xerial:sqlite-jdbc`, `org.postgresql:postgresql`, `com.mysql:mysql-connector-j` or `org.mariadb.jdbc:mariadb-java-client`. None is a dependency of CronWatch. The alert channels and Claude triage post over the JDK's own `java.net.http.HttpClient`.

Until the first release, build it from this repository:

```bash
cd packages/java && ./mvnw -B install -DskipTests
```

```xml
<dependency>
  <groupId>dev.cronwatch</groupId>
  <artifactId>cronwatch</artifactId>
  <version>0.8.0</version>
</dependency>
```

## Use

One client per app, kept where the app keeps its `DataSource` and closed at shutdown:

```java
var dataSource = new org.sqlite.SQLiteDataSource();
dataSource.setUrl("jdbc:sqlite:data/cronwatch.db");

try (Cronwatch cw = Cronwatch.builder()
    .store(SqlStore.sqlite(dataSource))              // default: a MemoryStore
    .alert(Channel.of("pager", (alert, ctx) -> System.out.println(alert.title())))
    .retention("30d")
    .build()) {

  Job nightly = cw.job("nightly-report", JobOptions.builder()
      .schedule("0 2 * * *").timezone("UTC")
      .grace("15m").timeout(Duration.ofMinutes(30))
      .expect("Report written").budget("cost", 2));

  nightly.run(job -> {
    Files.writeString(Path.of("report.txt"), "done"); // an IOException thrown here is thrown from run()
    job.log("Report written");                        // kept with the run, shown in alerts
    job.metric("cost", 1.2);                          // watched against budgets and baselines
  });

  Path path = nightly.call(job -> Files.writeString(Path.of("report.txt"), "done"));

  CheckResult result = cw.check();                    // missed and stuck runs, retries, pruning
  cw.silence("nightly-report", "2h");
}
```

`run` takes a function that returns nothing and `call` one that returns a value; each runs the function in the calling thread, where your transaction, MDC and security context live, as a recorded run. Anything the function throws, checked or not, fails the run and is thrown again as it came, its type and stack intact, so your own error handling sees exactly what it would have without CronWatch; the function types are generic in what they throw, so `run` declares exactly the checked exceptions your lambda throws. A `String` `call`'s function returns is the run's output when nothing was logged (and what `expect` checks), and an HTTP answer of 400 or more (`java.net.http.HttpResponse`, Spring's `ResponseEntity`) fails the run. The store failing never stops a job: its failures go to the error handler (`onError`, by default `System.Logger` named `dev.cronwatch`).

Durations take the SDK's text (`"15m"`, `"1h30m"`, stored as written), a `java.time.Duration` or milliseconds. `expect` takes the text the output must contain, `expectMatch(source, flags)` for a JavaScript regular expression (run by the port's own engine, so it reads as the SDK reads it; a `java.util.regex.Pattern` is not taken, since it reads a pattern differently), or `expectThat(predicate)`. A bad option, schedule or zone is a `CronwatchException` from `job()` with the SDK's message.

`start()` checks every minute, for a long-running service; a program a crontab runs calls `check()` instead, from a line of its own.

### Threads and time

`Cronwatch.current()` answers the run the calling thread is in, so code deep in a call chain can log to it. A thread the job starts has none of its own: `job.wrap(runnable)` carries it across, and so does Micrometer's context propagation (Spring's `ContextPropagatingTaskDecorator`, Reactor's automatic propagation) when it is on the class path. With SLF4J on the class path, `cronwatch_job` and `cronwatch_run` are in the MDC during a run.

A job's timeout sets `job.cancelled()` and calls what `job.onCancel(...)` registered; nothing is stopped, as the SDK stops nothing. `RunOptions.interruptAtTimeout()` also interrupts the running thread at the timeout, and a run that then ends by throwing is recorded as timed out, so the stuck alert goes out at once. When the JVM begins to stop (`System.exit`, a `SIGTERM`), a shutdown hook records every run still open in the process as failed (`noShutdownHook()` leaves it out). The client's own work (recording a run, sending alerts, checks) runs on virtual threads of its own, and an interrupt of the caller never cuts a write in half.

```java
try (Cronwatch cw = Cronwatch.builder().build()) {
  Job sync = cw.job("sync", JobOptions.builder().timeout("5m"));
  sync.run(RunOptions.interruptingAtTimeout(), job -> {
    while (!job.cancelled()) {
      Thread.sleep(1000); // interrupted at the timeout
    }
  });
}
```

### Runs that span calls

```java
try (Cronwatch cw = Cronwatch.builder().build()) {
  Job ingest = cw.job("import");
  RunHandle run = ingest.start(StartOptions.id("batch-42")); // records a running run
  run.log("fetched 1,200 rows");
  run.flush();                                              // appends what was logged so far
  // later, perhaps in another process:
  RunHandle again = cw.resumeRun("import", "batch-42");
  again.finish();                                           // or again.fail(exception)
}
```

### Stores

`MemoryStore` is the default, for tests and trying it out. `SqlStore.sqlite(dataSource)` keeps the SDK's three tables in a SQLite database, in WAL mode, through one connection it keeps; `SqlStore.postgres(dataSource)` keeps them in Postgres (`JSONB` for the JSON, many processes may start at once), and `SqlStore.mysql(dataSource)` in MySQL 8.0.13 or newer or MariaDB 10.6 or newer; `SqlStore.of(dataSource)` picks the dialect from the driver, and `.prefix("cw_")` sets the table prefix. The tables are made on first use, byte for byte as the SDK makes them, so a Node process and a Java process can share them in either order. The store's writes never join a transaction your code has open: each statement takes a connection of its own from the data source, in autocommit, so give it a plain data source, not one that hands out your transaction's connection.

```java
var dataSource = new org.postgresql.ds.PGSimpleDataSource();
dataSource.setUrl("jdbc:postgresql://localhost/app");
Cronwatch cw = Cronwatch.builder().store(SqlStore.postgres(dataSource)).build();
```

A store of your own implements `dev.cronwatch.store.Store` and is held to the contract every store passes, from any test framework:

```java
dev.cronwatch.storetest.StoreContract.run(new MemoryStore());
```

`StoreReplay` replays the SDK's recorded store cases (`conformance/store.json`, which your test reads), and `FinishOnce` runs several clients over one database to hold a run to being recorded and judged once.

### Alerts

`Console` is the default channel. The SDK's fifteen are in `dev.cronwatch.alerts`, request for request: Slack, Discord and a signed webhook; the email providers Resend, Postmark, SendGrid, Mailgun and SES (signed with SigV4, no AWS SDK); Twilio for SMS; and the trackers Sentry, Honeybadger, Datadog, Rollbar, Bugsnag and New Relic. Each is made from its options, whose `build()` refuses what the SDK refuses:

```java
Cronwatch cw = Cronwatch.builder()
    .alert(Slack.webhook(System.getenv("SLACK_WEBHOOK_URL")))
    .alert(Resend.channel(ResendOptions.builder()
        .apiKey(System.getenv("RESEND_API_KEY"))
        .from("CronWatch <alerts@example.com>").to("ops@example.com")
        .link(alert -> "https://app.example.com/cronwatch/jobs/" + alert.job())
        .build()))
    .build();
```

Every request is made the way the SDK makes it: one ten second deadline for the whole request, a redirect refused rather than followed (so credentials never go where it points), at most 1 MiB of an answer read as it arrives, TLS always verified, and an error that names the provider and the URL's origin only, with every secret the channel holds cut out of any answer it quotes. The requests go through the client's `Transport`: by default a `JdkTransport` over one `HttpClient` the client makes on its first send and closes with itself. An app that wants a proxy, its own trust store or another HTTP client gives one, to the client (`Cronwatch.builder().transport(...)`) or to one channel's options (`.transport(...)`); a transport must not follow redirects. The JDK sets `host`, `connection`, `content-length`, `expect` and `upgrade` itself, so a webhook header of those names is dropped.

### Claude triage

```java
Cronwatch cw = Cronwatch.builder()
    .triage(Anthropic.triage(AnthropicOptions.builder()
        .context("A Spring Boot service on Kubernetes with a Postgres database.")
        .build()))
    .build();
```

Each alert but a recovery gets a few sentences from Claude on what went wrong, from one POST to the Messages API (no Anthropic client), the request the SDK's official client makes. The key is `apiKey(...)`, else `ANTHROPIC_API_KEY`, read when triage runs; `ANTHROPIC_BASE_URL` or `baseUrl(...)` points it at a gateway. It is tried once per alert, and never holds an alert up for more than 25 seconds.

### pg_cron

```java
var dataSource = new org.postgresql.ds.PGSimpleDataSource();
dataSource.setUrl("jdbc:postgresql://localhost/app");
Cronwatch cw = Cronwatch.builder()
    .store(SqlStore.postgres(dataSource))
    .source(PgCron.source(dataSource, PgCronOptions.builder()
        .prefix("db:")
        .options(JobOptions.builder().grace("5m"))
        .build()))
    .build();
cw.start();
```

The pg_cron source watches the jobs that run inside Postgres, where nothing can wrap them: each check reads `cron.job`, declares each job with its schedule, and copies new rows of `cron.job_run_details` in as runs, so a missed, failed, stuck or slow pg_cron job is alerted like any other. It needs a data source on the database pg_cron runs in (its `cron.database_name`). Jobs are named from their jobname (`prefix` in front); a paused job loses its schedule, and one renamed or dropped keeps its history without one.

## Testing this package

```bash
npm ci && npm run build        # at the repository root: the SDK, for the croner parity and Node compatibility tests
cd packages/java && ./mvnw -B verify
```

The tests replay every file in `conformance/` byte for byte, with `TZ=UTC` and `-Duser.timezone=UTC` as the fixtures are made (Surefire sets both). The Postgres, MySQL, MariaDB and pg_cron tests run when `CRONWATCH_TEST_PG`, `CRONWATCH_TEST_MYSQL`, `CRONWATCH_TEST_MARIADB` and `CRONWATCH_TEST_PGCRON` are set, as URLs (`postgres://postgres:pw@127.0.0.1:5432/cw`, `mysql://root:pw@127.0.0.1:3306/cw`), and skip, saying why, without them; each test uses tables of a prefix of its own, dropped at the end. The channels' hardening tests run against local servers on raw sockets, TLS with a certificate `keytool` makes at run time. The croner parity check and the SQLite file shared with Node need `node` and the built SDK, and skip, saying why, without them. The build compiles with Error Prone and `-Xlint:all` with warnings as errors, and the Enforcer holds the core to no dependencies and Java 21 bytecode; `./mvnw spotless:apply` formats the code (google-java-format), and CI runs `spotless:check`. CI runs it all on JDK 21 and the newest JDK. The README's examples are compiled by a test.

## License

MIT
