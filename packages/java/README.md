# cronwatch for Java

Cron and scheduled-job monitoring that lives inside your JVM service. Wrap a job once; every run is recorded in a database you already have, and you are told when a run is missed, fails, gets stuck, runs slow or goes over budget. No server to run, no account to make. This is the library behind [cronwatch.dev](https://cronwatch.dev).

This is the Java port of [`@cronwatch/sdk`](https://www.npmjs.com/package/@cronwatch/sdk): the same rules, the same alert text and the same stored rows, so a Java process and a Node, Ruby, Python, PHP, Go, Rust or Elixir process can share one database, and every port reads the tables the others write. It is built in phases ([DESIGN.md](DESIGN.md) has the plan and how each part works). Phase 1, this one, has the core: jobs, runs in the calling thread, runs that span calls, checks, silences, sources, deferred delivery and the triage hook, the current run across threads, the shutdown hook, the memory store, and the SQL store over JDBC on SQLite. Postgres, MySQL and MariaDB, the SDK's fifteen alert channels, Claude triage and the pg_cron source come in phase 2; the dashboard, a job's handler and the servlet and Spring Boot adapters in phase 3. Phase 4 has the scheduler integrations: the Spring Boot starter (the client from `cronwatch.*` properties, every `@Scheduled` method watched with no code changes, ShedLock), `cronwatch-quartz` and `cronwatch-jobrunr`, and `CronwatchCli` for a check from a crontab line.

It is not on Maven Central yet. The first release will be `dev.cronwatch:cronwatch`.

## Install

Java 21 or newer. The core, `dev.cronwatch:cronwatch`, depends on nothing: cron expressions are read by a port of [croner](https://github.com/hexagon/croner), the parser the SDK uses, so every port agrees on every fire time; zones come from the JDK's own copy of the IANA database; JSON, the JavaScript regular expressions a stored `expect` pattern holds, and secret redaction are the port's own. The SQL store takes the app's `javax.sql.DataSource` and driver; for SQLite that is xerial's `org.xerial:sqlite-jdbc`.

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

`MemoryStore` is the default, for tests and trying it out. `SqlStore.sqlite(dataSource)` keeps the SDK's three tables in a SQLite database, in WAL mode, through one connection it keeps; `.prefix("cw_")` sets the table prefix. The tables are made on first use, byte for byte as the SDK makes them, so a Node process and a Java process can share them in either order. The store's writes never join a transaction your code has open. `SqlStore.postgres(dataSource)` holds the Postgres statements, run against a server from phase 2.

A store of your own implements `dev.cronwatch.store.Store` and is held to the contract every store passes, from any test framework:

```java
dev.cronwatch.storetest.StoreContract.run(new MemoryStore());
```

`StoreReplay` replays the SDK's recorded store cases (`conformance/store.json`, which your test reads), and `FinishOnce` runs several clients over one database to hold a run to being recorded and judged once.

## Spring Boot

`dev.cronwatch:cronwatch-spring-boot-starter`, for Spring Boot 3.5 and 4, makes the client a bean from `cronwatch.*` properties and the app's own beans: a `Store` bean is the store (else `SqlStore` over the app's one `DataSource`, else the memory store), every `Channel` bean is a channel, and a `Triage`, `Source` beans and an `ErrorHandler` are used when the app has them. An app's own `Cronwatch` bean replaces it.

```properties
cronwatch.store=auto                  # auto, memory or jdbc (the app's DataSource)
cronwatch.retention=30d
cronwatch.defaults.grace=10m
cronwatch.check-every=1m
cronwatch.check-mode=auto             # auto, local, shedlock, quartz or none
cronwatch.app=billing                 # default: $CRONWATCH_APP_ID, else spring.application.name
cronwatch.jobs[NightlyReports.build].grace=15m
```

With `@EnableScheduling`, every `@Scheduled` method is watched with no code changes (`cronwatch.scheduled.enabled=false` turns it off). Each invocation is a run, recorded from the `Observation` Spring makes of it, in the thread that runs the method, so `Cronwatch.current()` works inside it; a method that throws fails its run and Spring's error handler does what it did before. A job is named `SimpleClassName.method` after the bean's own class, the full name when two classes' simple names would give one name, and `@CronwatchJob` names it and gives its options:

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

`dev.cronwatch:cronwatch-quartz` watches a Quartz 2.5 scheduler (the starter does it for every `Scheduler` bean). Every job the scheduler holds with a trigger is declared (`nightlyReport` in the `DEFAULT` group, `reports.nightly` for `nightly` in `reports`), and every firing is a run, opened in the worker thread before `execute` and closed after it, failed with what the job threw:

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

## Testing this package

```bash
npm ci && npm run build        # at the repository root: the SDK, for the croner parity and Node compatibility tests
cd packages/java && ./mvnw -B verify
```

The tests replay `conformance/` byte for byte, with `TZ=UTC` and `-Duser.timezone=UTC` as the fixtures are made (Surefire sets both). The croner parity check and the SQLite file shared with Node need `node` and the built SDK, and skip, saying why, without them. The build compiles with Error Prone and `-Xlint:all` with warnings as errors, and the Enforcer holds the core to no dependencies and Java 21 bytecode; `./mvnw spotless:apply` formats the code (google-java-format), and CI runs `spotless:check`. CI runs it all on JDK 21 and the newest JDK. The README's examples are compiled by a test (the integrations' in the starter's tests). The integrations' tests run real schedulers on the JVM's clock: `-Dspring-boot.version=`, `-Dshedlock.version=`, `-Dquartz.version=` and `-Djobrunr.version=` pick the releases they run against (CI's `java-frameworks` runs the oldest and newest of each), and the Quartz recovery test runs on the JDBC job store over Postgres when `CRONWATCH_TEST_PG` is set.

## License

MIT
