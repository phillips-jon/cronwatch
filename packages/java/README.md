# cronwatch for Java

Cron and scheduled-job monitoring that lives inside your JVM service. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make. This is the library behind [cronwatch.dev](https://cronwatch.dev).

This is the Java port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk): the same rules, the same alert text and the same stored rows, so a Java process and a Node, Ruby, Python, PHP, Go, Rust or Elixir process can share one database, and every port reads the tables the others write. It is built in phases ([DESIGN.md](DESIGN.md) has the plan and how each part works). Phase 1 has the core: jobs, runs in the calling thread, runs that span calls, checks, silences, sources, deferred delivery and the triage hook, the current run across threads, the shutdown hook, the memory store, and the SQL store over JDBC on SQLite. Phase 2 adds the SQL store on Postgres, MySQL and MariaDB, the SDK's fifteen alert channels, Claude triage and the pg_cron source. Phase 3 adds the dashboard and its JSON API and a job's handler, framework-free, with adapters for the JDK's own HTTP server, servlet containers (`dev.cronwatch:cronwatch-servlet`) and Spring MVC and WebFlux (`dev.cronwatch:cronwatch-spring-boot-starter`). Phase 4 has the scheduler integrations: the Spring Boot starter's (every `@Scheduled` method watched with no code changes, ShedLock, the app's Quartz schedulers when `cronwatch-quartz` is a dependency), `cronwatch-quartz` and `cronwatch-jobrunr`, and `CronwatchCli` for a check from a crontab line.

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
  <version>0.10.0</version>
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

A store of your own implements `dev.cronwatch.store.Store`, building the records it hands back with their static factories (`Run.of(...)`, `StoredJob.of(...)`, and `JobState.fromJson` for the state's JSON) rather than their canonical constructors, since a record may gain a component in a 1.x release. It is held to the contract every store passes, from any test framework:

```java
dev.cronwatch.storetest.StoreContract.run(new MemoryStore());
```

`StoreContract.run` is the kit's one entry point, and the only part of `dev.cronwatch.storetest` the 1.x releases promise. (Before 1.0 the package also published `StoreReplay`, `FinishOnce`, `ForeignRows` and `StoreContract.newRun`, the parts the port's own store tests use; they are internal now.)

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

Every request is made the way the SDK makes it: one ten second deadline for the whole request, a redirect refused rather than followed (so credentials never go where it points), at most 1 MiB of an answer read as it arrives, TLS always verified, and an error that names the provider and the URL's origin only, with every secret the channel holds cut out of any answer it quotes. The requests go through the client's `Transport`: by default a `JdkTransport` over one `HttpClient` the client makes on its first send and closes with itself. An app that wants a proxy, its own trust store or another HTTP client gives one, to the client (`Cronwatch.builder().transport(...)`) or to one channel's options (`.transport(...)`). A transport is one method, `post(Transport.Request)`, answering a `Transport.Response` once the answer's head has arrived, its body read a chunk at a time; it must not follow redirects. The JDK sets `host`, `connection`, `content-length`, `expect` and `upgrade` itself, so a webhook header of those names is dropped.

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
cw.startChecking();
```

The pg_cron source watches the jobs that run inside Postgres, where nothing can wrap them: each check reads `cron.job`, declares each job with its schedule, and copies new rows of `cron.job_run_details` in as runs, so a missed, failed, stuck or slow pg_cron job is alerted like any other. It needs a data source on the database pg_cron runs in (its `cron.database_name`). Jobs are named from their jobname (`prefix` in front); a paused job loses its schedule, and one renamed or dropped keeps its history without one.

### The dashboard

`cw.routes()` is the SDK's dashboard and small JSON API: the same pages, URLs, JSON, cookie and token rules, so [`@cronwatch/mcp`](https://www.npmjs.com/package/@cronwatch/mcp) works against a Java app as it does against a Node one. It is framework-free (`Routes.handle` takes a `dev.cronwatch.web.Request` and answers a `Response`), and served by an adapter. On the JDK's own server:

```java
try (Cronwatch cw = Cronwatch.builder().build()) {
  HttpServer server = HttpServer.create(new InetSocketAddress(8080), 0);
  server.setExecutor(Executors.newVirtualThreadPerTaskExecutor()); // the routes read the store
  WebServer.mount(server, "/cronwatch", cw.routes(RoutesOptions.builder()
      .token(System.getenv("CRONWATCH_TOKEN"))
      .build()));
  server.start();
}
```

Send the token as `Authorization: Bearer <token>`, or open the dashboard once with `?token=<token>` and a cookie holds a digest of it. Without a token it is `CRONWATCH_TOKEN`; with none at all it answers 503, except in development (`CRONWATCH_ENV` or `APP_ENV` naming it), where it makes one and prints a sign-in link to standard output, showing the host only when `origin` is set or the request came to a loopback host. `RoutesOptions.noToken()` serves it open behind your own auth; `origin(...)` and `trustProxy()` are for an app behind a proxy. A body past 1 MiB is answered 413.

In a servlet container (Tomcat 10.1, Jetty 12, any Jakarta EE 10 or 11 server), `dev.cronwatch:cronwatch-servlet` has `CronwatchFilter`, which answers the requests under its path (`/cronwatch` by default, within the web app's context) and passes every other one down the chain, so it can sit ahead of your own servlets and security. In a Spring Boot app, `dev.cronwatch:cronwatch-spring-boot-starter` registers it on Spring MVC, or a `WebFilter` on WebFlux, from `cronwatch.web.*`:

```properties
cronwatch.web.path=/cronwatch
cronwatch.web.token=${CRONWATCH_TOKEN}
# cronwatch.web.origin=https://app.example.com, cronwatch.web.open=true, cronwatch.web.order=-110
```

The filter runs ahead of Spring Security's chain (order -110, before its -100), since the dashboard checks its own token; with `cronwatch.web.open=true` it has none, so it runs behind the chain (order -90) and your security rules guard it. `cronwatch.web.order` sets either.

Tomcat, Jetty and Spring Security refuse an encoded slash (`%2F`) in a path by default, so a job whose name holds a `/` is reached through the dashboard behind them only if the app allows it; the JDK's server passes it through.

### A job's handler

For a platform cron that calls a URL (a Kubernetes CronJob with `curl`, Cloud Run jobs behind a scheduler), `job.handler(fn)` runs the job for each request that carries `Authorization: Bearer <CRON_SECRET>`, and answers with how the run went:

```java
try (Cronwatch cw = Cronwatch.builder().build()) {
  Job nightly = cw.job("nightly-report", JobOptions.builder().schedule("0 2 * * *"));
  Handler handler = nightly.handler((job, request) -> {
    job.log("Report written");
    return null;                                           // or a Response of your own
  });
  HttpServer server = HttpServer.create(new InetSocketAddress(8080), 0);
  WebServer.mount(server, "/cron/nightly", handler);
}
```

In a servlet container, `new CronwatchServlet(handler)` serves it.

## Spring Boot

`dev.cronwatch:cronwatch-spring-boot-starter`, for Spring Boot 3.5 and 4, makes the client a bean from `cronwatch.*` properties and the app's own beans: a `Store` bean is the store (else `SqlStore` over the app's one `DataSource`, else the memory store), every `Channel` bean is a channel, and a `Triage`, `Source` beans and an `ErrorHandler` are used when the app has them. When neither `CRONWATCH_ENV` nor `APP_ENV` is set, the environment is the app's active profile (`dev` and `local` are development, `prod` production). An app's own `Cronwatch` bean replaces it.

```properties
# auto, memory or jdbc (the app's DataSource)
cronwatch.store=auto
cronwatch.retention=30d
cronwatch.defaults.grace=10m
cronwatch.check-every=1m
# auto, local, shedlock, quartz or none
cronwatch.check-mode=auto
# default: $CRONWATCH_APP_ID, else spring.application.name
cronwatch.app=billing
cronwatch.jobs[NightlyReports.build].grace=15m
```

With `@EnableScheduling`, every `@Scheduled` method is watched with no code changes (`cronwatch.scheduled.enabled=false` turns it off). Each invocation is a run (trigger `spring-scheduled`; runs recorded before 1.0 carry `scheduled`), recorded from the `Observation` Spring makes of it, in the thread that runs the method, so `Cronwatch.current()` works inside it; a method that throws fails its run and Spring's error handler does what it did before. A job is named `SimpleClassName.method` after the bean's own class, the full name when two classes' simple names would give one name, and `@CronwatchJob` names it and gives its options:

```java spring
class NightlyReports {
  @org.springframework.scheduling.annotation.Scheduled(cron = "0 0 2 * * *", zone = "UTC")
  @CronwatchJob(name = "nightly-report", grace = "15m", expect = "Report written")
  void build() {
    Cronwatch.current().log("Report written");
  }
}
```

A `cron` is declared as written, in the annotation's zone (else the JVM's), and checked against Spring's own reading of it: Spring runs a job whose day of the month and day of the week are both given only when both match, where CronWatch (croner) runs it when either does, so an expression the two read differently is reported once and watched without a schedule. A `fixedRate` is `every <rate>`; so is a `fixedDelay`, whose runs start a delay after the last one ended, so give such a job a grace as long as its longest run. A method with several `@Scheduled` annotations is one job without a schedule. A method that returns a `Mono`, a `Flux` or a Kotlin flow, or suspends, is observed by Spring around its subscription rather than its work, so it is reported and watched without runs. Jobs are tagged `spring-scheduled` and `spring-scheduled:<app>`, so two apps sharing a store never unschedule each other's jobs.

**ShedLock.** When the app runs its `@Scheduled` methods on every instance under ShedLock's `@SchedulerLock`, the starter wraps the app's `LockProvider`, so the instances that do not get the lock give their run back and only the one that ran the method records it.

**The check** runs every `cronwatch.check-every` from when the context starts, with each integration's sync before it (jobs gone from the app declared again without their schedule, so they are never reported missed). How it runs across a cluster is `cronwatch.check-mode`: under a ShedLock lock of its own name (`cronwatch-check`) when the app has a `LockProvider`, as a Quartz job when the app's Quartz scheduler is clustered, else in each instance.

## Quartz

`dev.cronwatch:cronwatch-quartz` watches a Quartz 2.5 scheduler. In a Spring Boot app, the starter does it for every `Scheduler` bean once `cronwatch-quartz` is a dependency of the app: the starter's dependency on it is optional, so it does not bring it in. Every job the scheduler holds with a trigger is declared (`nightlyReport` in the `DEFAULT` group, `reports.nightly` for `nightly` in `reports`), and every firing is a run, opened in the worker thread before `execute` and closed after it, failed with what the job threw:

```java quartz
Cronwatch cw = Cronwatch.builder().build();
org.quartz.Scheduler scheduler = org.quartz.impl.StdSchedulerFactory.getDefaultScheduler();
CronwatchQuartz.watch(cw, scheduler, QuartzOptions.defaults().app("billing"));
CronwatchQuartz.scheduleCheck(scheduler);   // a check every minute, once per cluster
scheduler.start();
```

A cron trigger is declared on its expression in the trigger's zone, checked against Quartz's own fire times; Quartz counts the days of the week from 1 for Sunday, so an expression naming one by number is reported and watched without a schedule (use `MON`, not `2`). A simple trigger repeating forever is `every <interval>`; other triggers, a trigger with a `Calendar`, and several triggers on different schedules make a job without a schedule. A refire (`refireImmediately`) is a new run. In a clustered job store, a job a node was running when it died is fired again on another node, and that firing finishes the earlier run as failed (`Quartz recovered the job after its node stopped`).

## JobRunr

`dev.cronwatch:cronwatch-jobrunr` is a server filter for JobRunr 8: every recurring job is declared by its id with its schedule (a cron in its zone, checked against JobRunr's own fire times, or `every <interval>`), and every attempt is a run in the worker thread, so a retry is a run of its own. A job that is not recurring is watched when its JobRunr name is given to `watchJob`.

```java jobrunr
Cronwatch cw = Cronwatch.builder().build();
var storage = new org.jobrunr.storage.InMemoryStorageProvider();
var watcher = CronwatchJobRunr.watch(cw, storage, JobRunrOptions.defaults().watchJob("send-invoice"));
var scheduler = org.jobrunr.configuration.JobRunr.configure()
    .useStorageProvider(storage)
    .withJobFilter(watcher)                   // before the server, as JobRunr asks
    .useBackgroundJobServer()
    .initialize()
    .getJobScheduler();
CronwatchJobRunr.scheduleCheck(scheduler);    // a check every minute, once per cluster
```

In a Spring Boot app with JobRunr's own starter, give the filter to its background job server as that starter's documentation says.

## A crontab

A program a crontab runs needs no integration: run the job, and check from a second crontab line on the same store. The check needs the same store and channels as the job, so it is a `main` of the app's own:

```java
final class CronwatchMain {
  public static void main(String[] args) {
    var dataSource = new org.sqlite.SQLiteDataSource();
    dataSource.setUrl("jdbc:sqlite:/var/lib/app/cronwatch.db");
    CronwatchCli.main(() -> Cronwatch.builder().store(SqlStore.sqlite(dataSource)).build(), args);
  }
}
```

```
*/5 * * * *  java -cp app.jar com.example.CronwatchMain check
```

`check` prints `cronwatch: checked 3 jobs, sent 1 alert` and exits non-zero when the check fails, so cron mails it; code already running in an app calls `CronwatchCli.run`, which answers the status and never ends the JVM. `examples/crontab` is such a program on SQLite.

## Deprecated

These still work, marked `@Deprecated(forRemoval = true)`, through every 1.x release, and go in 2.0: `cw.start()` and its overloads (use `cw.startChecking()`); `dev.cronwatch.jdbc.SqlStore` (use `dev.cronwatch.store.SqlStore`, the same store, now beside `MemoryStore`); `dev.cronwatch.bridge.Bridge` (use `SchedulerBridge`, the .NET port's name; the bridge is for integration authors and outside the 1.x promise); `Routes.of(cw, options)` (use `cw.routes(options)`). `Json.quote`, `Json.kind`, `Json.copy`, `Json.MAX_DEPTH`, pg_cron's helpers (`PgCron.schedule`, `jobName`, `run`, `HOLD_MS`, `PgCronRow`), `Twilio.MAX_SEGMENTS` and every part of `dev.cronwatch.storetest` but `StoreContract.run` are internal from 1.0. The [Java docs](https://cronwatch.dev/docs/java/#deprecated) have the list.

## Testing this package

```bash
npm ci && npm run build        # at the repository root: the SDK, for the croner parity and Node compatibility tests
cd packages/java && ./mvnw -B verify
```

The tests replay every file in `conformance/` byte for byte, with `TZ=UTC` and `-Duser.timezone=UTC` as the fixtures are made (Surefire sets both). The Postgres, MySQL, MariaDB and pg_cron tests run when `CRONWATCH_TEST_PG`, `CRONWATCH_TEST_MYSQL`, `CRONWATCH_TEST_MARIADB` and `CRONWATCH_TEST_PGCRON` are set, as URLs (`postgres://postgres:pw@127.0.0.1:5432/cw`, `mysql://root:pw@127.0.0.1:3306/cw`), and skip, saying why, without them; each test uses tables of a prefix of its own, dropped at the end. The channels' hardening tests run against local servers on raw sockets, TLS with a certificate `keytool` makes at run time. The croner parity check and the SQLite file shared with Node need `node` and the built SDK, and skip, saying why, without them. The dashboard replays the SDK's recorded answers (`packages/ruby/test/web/golden.json`) straight into the routes, through the JDK's server, through the servlet filter under Jetty, and through the starter on Spring MVC under Tomcat and on WebFlux under Netty; `CRONWATCH_TEST_JAVA=1 npm test --workspace packages/mcp` drives the MCP server against `webserver`, a seeded dashboard. The build compiles with Error Prone and `-Xlint:all` with warnings as errors, and the Enforcer holds the core to no dependencies and Java 21 bytecode; `./mvnw spotless:apply` formats the code (google-java-format), and CI runs `spotless:check`. CI runs it all on JDK 21 and the newest JDK. The README's examples are compiled by a test (the integrations' in the starter's tests). The integrations' tests run real schedulers on the JVM's clock: `-Dspring-boot.version=`, `-Dshedlock.version=`, `-Dquartz.version=` and `-Djobrunr.version=` pick the releases they run against (CI's `java-frameworks` runs the oldest and newest of each), and the Quartz recovery test runs on the JDBC job store over Postgres when `CRONWATCH_TEST_PG` is set.

## License

MIT
