---
title: Java schedulers
description: Watch Spring's @Scheduled methods with no code changes, ShedLock, Quartz, and JobRunr: jobs declared from the scheduler's own schedules, checked against its fire times, every run and retry recorded in the thread that runs it, and the check running once per cluster. Plus a plain crontab.
order: 3.96
group: Java
---

# Java schedulers

A scheduler your JVM service already runs is watched with no change to its jobs: the integration reads the scheduler's own schedules and records each run in the thread that runs it. In a Spring Boot app, the starter does it all from properties; outside Spring, the Quartz and JobRunr modules are one call each. Everything else (the client, the store, the channels, the dashboard) is the [Java page](/docs/java/).

| Scheduler | Artifact | Supported | The check |
|---|---|---|---|
| [Spring `@Scheduled`](#spring-boot) | `cronwatch-spring-boot-starter` | Spring Boot 3.5 and 4 | the starter's own, every `cronwatch.check-every` |
| [ShedLock](#shedlock) | `cronwatch-spring-boot-starter` | ShedLock 6.10 and 7 | the starter's, under a lock of its own |
| [Quartz](#quartz) | `cronwatch-quartz` | Quartz 2.5 | `CronwatchCheckJob`, once per cluster |
| [JobRunr](#jobrunr) | `cronwatch-jobrunr` | JobRunr 8 | a recurring job of its own, once per cluster |

A program a crontab runs needs no integration: see [a crontab](#a-crontab) below.

## What every integration does

- **Jobs are declared from the scheduler.** Each method, job, or recurring job the scheduler runs on a schedule is a CronWatch job with that schedule, in that entry's zone, so a job that stops running is reported missed without you writing a cron expression twice. Each cron is checked against the scheduler's own fire times: Spring, Quartz, and JobRunr each read some expressions differently from CronWatch (like cron, and croner in the SDK), so an expression the two read differently is reported once to the error handler and its job watched without a schedule. Its failures, duration, budgets, and floors still alert, but it is never reported missed. A fixed rate or interval is `every <interval>`, and a job with several schedules is one job without a schedule.
- **Jobs gone lose their schedule.** A job taken out of the scheduler, in this process or since an earlier deploy, is declared again without its schedule, so it keeps its history and is never reported missed; a missed alert already open closes with a recovery.
- **Jobs belong to an app.** Every job is tagged with the integration (`spring-scheduled`, `quartz`, `jobrunr`, the same names its runs carry as their trigger) and the app (`quartz:billing`), and the app is in its runs' ids, so two apps sharing a store never take each other's jobs for gone. The app is the integration's `app` option (`cronwatch.app` in the starter), else `CRONWATCH_APP_ID`, else `spring.application.name` in the starter, else the main class. Every instance of one app needs the same. Job names are the scheduler's own, with no prefix; [Triggers, tags, and job names](/docs/dashboard/#triggers-tags-and-job-names) has the rule every integration follows.
- **Each run is a run in the scheduler's own thread.** The run is opened just before the job's code runs, in the thread that runs it, and closed just after, so `Cronwatch.current()` works inside the job with no code, and `cronwatch_job` and `cronwatch_run` are in the MDC. A job that throws fails its run, and the scheduler's own error handling does what it did before.
- **Options per job.** Default options come first, then the schedule, then each job's own options, so a schedule given to one job replaces the scheduler's.

### Retries

For Quartz and JobRunr, every attempt is a run of its own. An attempt that fails is a failed run with its cause, so failing attempts open one failed alert and the attempt that succeeds closes it with a recovery; `failuresBeforeAlert(3)` counts failed attempts in a row. A Quartz refire (`refireImmediately`) is a new run. A `@Scheduled` method under ShedLock that did not get the lock did not run: its run is taken back, so nothing is judged, no alert is sent, and the failures in a row are left as they were. Taking a run back needs a store with `deleteRunIf`, which `MemoryStore` and `SqlStore` have.

### The check

Each integration's check runs a sync first: the scheduler's jobs are declared again, and the jobs of this app's that the store holds with a schedule the scheduler no longer has are declared again without it. Run it once a minute. `cw.startChecking()` checks too, but without the sync, so a job taken out of the scheduler by a deploy keeps its schedule and is reported missed; prefer the integration's check.

## Spring Boot

`dev.cronwatch:cronwatch-spring-boot-starter`, for Spring Boot 3.5 and 4, makes the client a bean from `cronwatch.*` properties and your app's own beans, watches every `@Scheduled` method, and serves the dashboard.

```xml
<dependency>
  <groupId>dev.cronwatch</groupId>
  <artifactId>cronwatch-spring-boot-starter</artifactId>
  <version>{{JAVA_VERSION}}</version>
</dependency>
```

```kotlin
// build.gradle.kts
implementation("dev.cronwatch:cronwatch-spring-boot-starter:{{JAVA_VERSION}}")
```

```properties
# application.properties
# store: auto, memory, or jdbc (the app's DataSource)
cronwatch.store=auto
cronwatch.retention=30d
cronwatch.defaults.grace=10m
cronwatch.check-every=1m
# check-mode: auto, local, shedlock, quartz, or none
cronwatch.check-mode=auto
# app: by default $CRONWATCH_APP_ID, else spring.application.name
cronwatch.app=billing
cronwatch.jobs[NightlyReports.build].grace=15m
```

**The client.** A `Store` bean is the store, else `SqlStore` over your app's one `DataSource`, with `cronwatch.table-prefix` naming its tables, else the memory store. That is `cronwatch.store=auto`, the default: a database `SqlStore` does not know falls back to memory, but one that is only down fails the start. `memory` and `jdbc` choose outright. Every `Channel` bean is a channel (else the console), and a `Triage` bean, `Source` beans, and an `ErrorHandler` bean are used when your app has them. When neither `CRONWATCH_ENV` nor `APP_ENV` is set, the environment is the app's active profile (`dev` and `local` are development, `prod` production). The client is closed when the context closes. An app's own `Cronwatch` bean replaces the starter's, and `cronwatch.enabled=false` turns the starter off. The other properties: `cronwatch.cron-secret`, `cronwatch.deliver` (`now` or `at-check`), `cronwatch.redact` and `cronwatch.shutdown-hook`, each defaulting as the builder does, and `cronwatch.defaults.timeout`, `.timezone`, and `.failures-before-alert`.

```java
@Configuration
class Alerts {
  @Bean
  Channel slack(@Value("${SLACK_WEBHOOK_URL}") String url) {
    return Slack.webhook(url);
  }
}
```

### @Scheduled

With `@EnableScheduling`, every `@Scheduled` method is watched with no code changes (`cronwatch.scheduled.enabled=false` turns it off). Each invocation is a run (trigger `spring-scheduled`; runs recorded before 0.11 carry `scheduled`), recorded from the `Observation` Spring makes of it, in the thread that runs the method, so `Cronwatch.current()` works inside it; a method that throws fails its run and Spring's error handler does what it did before.

```java
@Component
class NightlyReports {
  @Scheduled(cron = "0 0 2 * * *", zone = "UTC")
  @CronwatchJob(name = "nightly-report", grace = "15m", expect = "Report written")
  void build() {
    Cronwatch.current().log("Report written");
  }
}
```

**Names.** A job is named `SimpleClassName.method` after the bean's own class (not its proxy's), the full class name when two classes' simple names would give one name. `@CronwatchJob` names it and gives its options (`name`, `description`, `grace`, `timeout`, `maxDuration`, `expect`, `tags`, `failuresBeforeAlert`), and `cronwatch.jobs[<name>].*` properties are given after them.

**Schedules.** A `cron` is declared as written, in the annotation's zone (else the JVM's), and checked against Spring's own reading of it. Spring runs a job whose day of the month and day of the week are both given only when both match, where CronWatch (croner) runs it when either does, so an expression the two read differently is reported once and watched without a schedule. A `fixedRate` is `every <rate>`; so is a `fixedDelay`, whose runs start a delay after the last one ended, so give such a job a grace as long as its longest run. A method with several `@Scheduled` annotations is one job without a schedule. A method that returns a `Mono`, a `Flux`, or a Kotlin flow, or suspends, is observed by Spring around its subscription rather than its work, so it is reported and watched without runs.

### ShedLock

When your app runs its `@Scheduled` methods on every instance under ShedLock's `@SchedulerLock`, the starter wraps your `LockProvider` beans, so in the method's thread it knows whether the lock was taken: the instances that did not get the lock give their run back, and only the one that ran the method records it. Nothing to configure: it is on whenever ShedLock and a `LockProvider` are there.

### The check

The starter runs its own check every `cronwatch.check-every` (a minute by default, the first a second after the context starts, five seconds at least), with each integration's sync before it, from when the context has started until it stops; as the context stops, it waits up to 30 seconds for a check under way, before the client is closed. How it runs across a cluster is `cronwatch.check-mode`:

| Mode | |
|---|---|
| `auto` | `shedlock` when the app has a `LockProvider`, else `quartz` when its Quartz scheduler is clustered, else `local` |
| `local` | in each instance, on the interval |
| `shedlock` | once per interval across the cluster, under a ShedLock lock named `cronwatch-check` |
| `quartz` | once per interval across the cluster, as a Quartz job (`CronwatchCheckJob`) |
| `none` | never: the app runs its checks elsewhere |

### The dashboard in Spring

The starter serves the dashboard on Spring MVC through the servlet filter, or on WebFlux through a `WebFilter`, from `cronwatch.web.*`:

```properties
# the path is within the app's context path
cronwatch.web.path=/cronwatch
cronwatch.web.token=${CRONWATCH_TOKEN}
# cronwatch.web.origin=https://app.example.com
# cronwatch.web.trust-proxy=true
# cronwatch.web.open=true
# cronwatch.web.order=-110
# cronwatch.web.enabled=false
```

The filter runs ahead of Spring Security's chain (order -110, before its -100), since the dashboard checks its own token. With `cronwatch.web.open=true` it has none, so it runs behind the chain (order -90) and your security rules guard it. `cronwatch.web.order` sets either. A `Routes` bean of your own replaces the one the starter makes. The token and every other rule are the [Java page's](/docs/java/#the-dashboard).

A job's handler, for a platform cron that calls a URL, is a `CronwatchFilter` of `dev.cronwatch:cronwatch-servlet` (which the starter brings) in a `FilterRegistrationBean`:

```java
@Bean
FilterRegistrationBean<CronwatchFilter> nightlyHandler(Cronwatch cw, Reports reports) {
  Handler handler = cw.job("nightly-report", JobOptions.builder().schedule("0 2 * * *"))
      .handler((job, request) -> reports.build(job));
  return new FilterRegistrationBean<>(new CronwatchFilter(handler, "/cron/nightly"));
}
```

## Quartz

`dev.cronwatch:cronwatch-quartz` watches a Quartz 2.5 scheduler. In a Spring Boot app, add it beside the starter and every `Scheduler` bean is watched, before Spring starts it (`cronwatch.quartz.enabled=false` turns it off). Elsewhere:

```java
Cronwatch cw = Cronwatch.builder().store(SqlStore.postgres(dataSource)).build();
Scheduler scheduler = StdSchedulerFactory.getDefaultScheduler();
CronwatchQuartz.watch(cw, scheduler, QuartzOptions.defaults()
    .app("billing")
    .jobDefaults(JobOptions.builder().grace("5m"))
    .job("reports.nightly", JobOptions.builder().expect("Report written")));
CronwatchQuartz.scheduleCheck(scheduler);    // a check every minute, once per cluster
scheduler.start();
```

Call `watch` before the scheduler starts, so no firing goes unrecorded; `close()` on what it returns stops it.

**Which jobs.** Every job the scheduler holds with a trigger is a job, named after its `JobKey`: `nightlyReport` in the `DEFAULT` group, `reports.nightly` for `nightly` in `reports`. The jobs are read when the integration starts, again when the scheduler says a job or trigger was added or removed, and every minute besides (`readEvery` sets it). A job with a `CronTrigger` is declared on its expression in the trigger's zone (a `?` read as `*`), checked against Quartz's own fire times. Quartz counts the days of the week from 1 for Sunday, so an expression naming one by number is reported and watched without a schedule: write `MON`, not `2`. A `SimpleTrigger` repeating forever is `every <interval>`; any other trigger, a trigger with a `Calendar`, and several triggers on different schedules make a job without a schedule.

**Runs.** A global `JobListener` opens each firing's run (trigger `quartz`) in the worker thread before `execute` and closes it after, failed with what the job threw (the `JobExecutionException`'s cause when it has one), so `Cronwatch.current()` works inside `execute`. A vetoed firing, and one `@DisallowConcurrentExecution` held back, opens nothing. In a clustered job store, a job a node was running when it died is fired again on another node, and that firing first finishes the earlier run, failed with `Quartz recovered the job after its node stopped`. Only the run of the node that died is finished so: a run of another node still alive, in a cluster of three or more, is left to finish.

**The check.** `CronwatchQuartz.scheduleCheck(scheduler)` schedules `CronwatchCheckJob`, which runs the sync and a check every minute; in a clustered job store Quartz fires it on one node, so it runs once per cluster. Its runs are never a job.

## JobRunr

`dev.cronwatch:cronwatch-jobrunr` is a server filter for JobRunr 8. Give it to the background job server:

```java
Cronwatch cw = Cronwatch.builder().store(SqlStore.postgres(dataSource)).build();
CronwatchJobRunr watcher = CronwatchJobRunr.watch(cw, storageProvider, JobRunrOptions.defaults()
    .app("billing")
    .job("nightly-report", JobOptions.builder().expect("Report written"))
    .watchJob("send-invoice"));
JobScheduler scheduler = JobRunr.configure()
    .useStorageProvider(storageProvider)
    .withJobFilter(watcher)                   // before the server, as JobRunr asks
    .useBackgroundJobServer()
    .initialize()
    .getJobScheduler();
CronwatchJobRunr.scheduleCheck(scheduler);    // a check every minute, once per cluster
```

In a Spring Boot app with JobRunr's own starter, give the filter to its background job server as that starter's documentation says.

**Which jobs.** Every recurring job is a job, named by its id, with its schedule: a cron in its zone, checked against JobRunr's own fire times, or `every <interval>` for a `Duration`. The recurring jobs are read when the integration starts and every minute besides (`readEvery` sets it), and a recurring job deleted is declared again without its schedule. A job that is not recurring is watched only when its JobRunr name (`@Job(name = "...")`) is given to `watchJob`, each attempt a run of the CronWatch job of that name, with no schedule, so a queue of a million emails is not a million runs.

**Runs.** JobRunr calls the filter in the worker thread just before the job runs and just after, so each attempt is a run (trigger `jobrunr`) opened and closed around the job in its own thread, and `Cronwatch.current()` works inside it. A job that throws fails its run; JobRunr's retries are runs of their own (see [Retries](#retries)).

**The check.** `CronwatchJobRunr.scheduleCheck(scheduler)` schedules a recurring job of its own (`cronwatch-check`) every minute, which runs the sync and a check once per minute across the servers sharing the storage provider. Its runs are never a job.

## A crontab

A program a crontab runs needs no integration: the job's line wraps its work in `job.run`, and a second line runs the check, both on a store they share.

```
# m  h  dom mon dow  command
0    2  *   *   *    java -cp app.jar com.example.Nightly
*/5  *  *   *   *    java -cp app.jar com.example.CronwatchMain check
```

`CronwatchMain` is a `main` of your own that calls `CronwatchCli.main(Nightly::cronwatch, args)` with the factory for your client; `check` runs one check, prints what it did, and exits non-zero when it fails. [From a crontab](/docs/java/#from-a-crontab) on the Java page has both sides.

## Writing an integration

The integrations above are built on `dev.cronwatch.bridge`: `SchedulerBridge` (the app's tag, a scheduler's fire times checked against CronWatch's, a job declared again without its schedule) and `Watch` (a scheduler's entries declared as jobs, one per name, tagged with the integration and the app). It is public for integration authors, but outside the 1.x promise: it changes when an integration needs it to, in any release, so pin the exact CronWatch version an integration of your own is built on. `Bridge`, `SchedulerBridge`'s name before 0.11, still works, deprecated.
