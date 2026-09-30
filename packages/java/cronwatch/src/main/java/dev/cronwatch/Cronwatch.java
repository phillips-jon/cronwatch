package dev.cronwatch;

import dev.cronwatch.Core.JobDef;
import dev.cronwatch.internal.core.CurrentRun;
import dev.cronwatch.internal.core.Friends;
import dev.cronwatch.internal.duration.Durations;
import dev.cronwatch.internal.duration.Schedules;
import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.internal.evaluate.Expect;
import dev.cronwatch.internal.evaluate.Format;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import java.io.IOException;
import java.io.InputStream;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Properties;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.function.LongSupplier;
import java.util.function.UnaryOperator;
import java.util.regex.Pattern;
import org.jspecify.annotations.Nullable;

/**
 * Watches an app's scheduled jobs: it records their runs in a store, judges each one, sends
 * alerts, and runs the checks that find missed and stuck runs. The same library as {@code
 * @cronwatch/sdk}, sharing its stores, its alert text and every byte it stores.
 *
 * <pre>{@code
 * var cw = Cronwatch.builder()
 *     .store(SqlStore.sqlite(dataSource))    // default: a MemoryStore
 *     .retention("30d")
 *     .build();
 *
 * Job nightly = cw.job("nightly-report", JobOptions.builder()
 *     .schedule("0 2 * * *").timezone("UTC")
 *     .grace("15m").expect("Report written"));
 *
 * nightly.run(job -> {
 *   reports.build();
 *   job.log("Report written");
 * });
 *
 * cw.check();                                // missed and stuck runs, retries, pruning
 * cw.start(Duration.ofMinutes(1));           // a check every minute, for a long-running service
 * }</pre>
 *
 * <p>One per app, kept where the app keeps its {@code DataSource} and closed at shutdown ({@link
 * #close}). Safe to use from any number of threads, platform or virtual. The calls block; the
 * client's own work runs on virtual threads of its own.
 */
public final class Cronwatch implements AutoCloseable {
  /** This library's version, as Maven built it. */
  public static final String VERSION = readVersion();

  static {
    Friends.set(new Friend());
  }

  private static final Pattern NAME = Pattern.compile("[A-Za-z0-9][A-Za-z0-9._:-]{0,119}");

  /** The options {@link Builder#defaults} takes, as the SDK's defaults. */
  private static final Set<String> DEFAULTABLE =
      Set.of("grace", "timeout", "timezone", "failuresBeforeAlert");

  /** Run ids that start with this belong to the pg_cron source. */
  public static final String RESERVED_RUN_ID_PREFIX = "pgcron:";

  final Core core;
  final Delivery delivery;
  final Runs runs;
  final Checks checks;
  private final @Nullable Thread shutdownHook;

  private Cronwatch(Core core, boolean shutdownHook) {
    this.core = core;
    this.delivery = new Delivery(core);
    this.runs = new Runs(core, delivery);
    this.checks = new Checks(this, core, runs, delivery);
    if (shutdownHook) {
      Thread hook = new Thread(runs::shutdown, "cronwatch-shutdown");
      Runtime.getRuntime().addShutdownHook(hook);
      this.shutdownHook = hook;
    } else {
      this.shutdownHook = null;
    }
  }

  private static String readVersion() {
    try (InputStream in = Cronwatch.class.getResourceAsStream("version.properties")) {
      if (in == null) {
        return "0.0.0";
      }
      Properties p = new Properties();
      p.load(in);
      return p.getProperty("version", "0.0.0");
    } catch (IOException e) {
      return "0.0.0";
    }
  }

  /** A builder with the SDK's defaults: an in-memory store, alerts to the console. */
  public static Builder builder() {
    return new Builder();
  }

  /**
   * The run the calling thread is in, or null outside one, so code deep in a call chain can log to
   * its run. A thread the job starts has none of its own: {@link JobContext#wrap(Runnable)} carries
   * it across, and so does Micrometer's context propagation when it is on the class path.
   */
  public static @Nullable JobContext current() {
    return CurrentRun.get();
  }

  // ---- jobs

  /**
   * Declares a job and returns its handle. Call it once, at startup, and keep the handle. Declaring
   * a name again replaces its definition.
   *
   * @throws CronwatchException for a name or option the SDK refuses, with its message
   */
  public Job job(String name, JobOptions options) {
    JobDef def = define(name, options);
    core.declare(def);
    return new Job(this, def);
  }

  /** The job {@link #job} would declare, checked and not declared. */
  JobDef define(String name, JobOptions options) {
    if (!NAME.matcher(name).matches()) {
      throw CronwatchException.invalid(
          "job name "
              + Json.quote(name)
              + " must be 1 to 120 characters of letters, digits, \".\", \"_\", \":\" or \"-\"");
    }
    JsObject fields = core.defaults.copy();
    for (Map.Entry<String, @Nullable Object> e : options.fields.entries()) {
      fields.set(e.getKey(), Json.copy(e.getValue()));
    }
    fields.set("name", name);
    Definition stored = Expect.toStored(fields, options.expect);
    validate(name, stored);
    return new JobDef(name, stored, options.expect);
  }

  /** {@link #job(String, JobOptions)} with no options. */
  public Job job(String name) {
    return job(name, JobOptions.builder());
  }

  /** The SDK's refusals of options that would otherwise quietly turn a check off. */
  private static void validate(String name, Definition def) {
    String quoted = Json.quote(name);
    try {
      if (def.has("schedule")) {
        Object v = def.get("schedule");
        if (!(v instanceof String text) || Js.trim(text).isEmpty()) {
          throw CronwatchException.invalid(
              "job " + quoted + ": schedule must be a non-empty string");
        }
        // The zone is checked below, with a message of its own; here only a good one is used.
        String tz = def.get("timezone") instanceof String z && Schedules.isZone(z) ? z : null;
        Schedules.parse(text, tz == null || tz.isEmpty() ? null : tz);
      }
      if (def.has("timezone")) {
        String tz = def.get("timezone") instanceof String z ? z : "";
        if (!Schedules.isZone(tz)) {
          throw CronwatchException.invalid(
              "job " + quoted + ": timezone " + Json.quote(tz) + " is not an IANA timezone");
        }
      }
      if (def.has("grace")) {
        Evaluate.graceMs(def);
      }
      if (def.has("timeout") && Evaluate.timeoutMs(def) <= 0) {
        throw CronwatchException.invalid("job " + quoted + ": timeout must be longer than zero");
      }
      if (def.has("maxDuration")
          && Durations.parseValue(def.get("maxDuration"), "maxDuration") <= 0) {
        throw CronwatchException.invalid(
            "job " + quoted + ": maxDuration must be longer than zero");
      }
      if (def.has("failuresBeforeAlert")) {
        Object v = def.get("failuresBeforeAlert");
        double n = v instanceof Number x ? x.doubleValue() : 0;
        if (!Js.isInteger(n) || n < 1) {
          throw CronwatchException.invalid(
              "job "
                  + quoted
                  + ": failuresBeforeAlert must be a whole number, 1 or more (got "
                  + Format.jsText(v)
                  + ")");
        }
      }
      if (def.get("budget") instanceof JsObject budget) {
        for (Map.Entry<String, @Nullable Object> e : budget.entries()) {
          double ceiling = e.getValue() instanceof Number x ? x.doubleValue() : 0;
          if (!Double.isFinite(ceiling) || ceiling < 0) {
            throw CronwatchException.invalid(
                "job "
                    + quoted
                    + ": budget."
                    + e.getKey()
                    + " must be a finite number, 0 or more (got "
                    + Js.formatNumber(ceiling)
                    + ")");
          }
        }
      }
    } catch (IllegalArgumentException e) {
      throw CronwatchException.invalid(
          Objects.requireNonNullElse(e.getMessage(), "invalid option"));
    }
  }

  private Job declared(String name, @Nullable JobOptions options) {
    JobDef def = options == null ? core.declared(name) : null;
    return def == null
        ? job(name, options == null ? JobOptions.builder() : options)
        : new Job(this, def);
  }

  /**
   * Runs a job by name without keeping a handle, declaring it on first use.
   *
   * @throws E what {@code fn} throws
   */
  public <E extends Exception> void run(String name, JobRunnable<E> fn) throws E {
    declared(name, null).run(fn);
  }

  /**
   * Runs a job by name, declaring it again with these options.
   *
   * @throws E what {@code fn} throws
   */
  public <E extends Exception> void run(String name, JobOptions options, JobRunnable<E> fn)
      throws E {
    declared(name, options).run(fn);
  }

  /**
   * {@link #run(String, JobRunnable)} for a function with a value.
   *
   * @throws E what {@code fn} throws
   */
  public <T extends @Nullable Object, E extends Exception> T call(String name, JobCallable<T, E> fn)
      throws E {
    return declared(name, null).call(fn);
  }

  /**
   * {@link #run(String, JobOptions, JobRunnable)} for a function with a value.
   *
   * @throws E what {@code fn} throws
   */
  public <T extends @Nullable Object, E extends Exception> T call(
      String name, JobOptions options, JobCallable<T, E> fn) throws E {
    return declared(name, options).call(fn);
  }

  /** The definitions declared in this process, in the order first declared. */
  public List<Definition> definedJobs() {
    return core.definedJobs();
  }

  /**
   * Writes the definition declared in this process under {@code name} to the store now, unless the
   * store already holds that definition (whatever order its keys come back in), and says whether it
   * wrote. A run or a check writes a declaration anyway, once; a scheduler integration calls this
   * so a process that only schedules still puts its jobs where the processes that run and check
   * them read them.
   *
   * @throws CronwatchException when the job is not declared here, or the store fails
   */
  public boolean syncJob(String name) {
    JobDef def = core.declared(name);
    if (def == null) {
      throw CronwatchException.invalid(
          "job " + Json.quote(name) + " is not declared in this process");
    }
    core.ensureReady();
    StoredJob stored = Core.call(() -> core.store.getJob(name));
    boolean write =
        stored == null || !sameJson(stored.definition().toObject(), def.stored().toObject());
    if (write) {
      Core.call(
          () -> {
            core.store.upsertJob(def.stored(), core.now());
            return null;
          });
    }
    core.markSynced(def);
    return write;
  }

  /** Whether two JSON values are equal, an object's keys in any order. */
  private static boolean sameJson(@Nullable Object a, @Nullable Object b) {
    if (a instanceof JsObject x && b instanceof JsObject y) {
      if (x.size() != y.size()) {
        return false;
      }
      for (Map.Entry<String, @Nullable Object> e : x.entries()) {
        if (!y.has(e.getKey()) || !sameJson(e.getValue(), y.get(e.getKey()))) {
          return false;
        }
      }
      return true;
    }
    if (a instanceof List<?> x && b instanceof List<?> y) {
      if (x.size() != y.size()) {
        return false;
      }
      for (int i = 0; i < x.size(); i++) {
        if (!sameJson(x.get(i), y.get(i))) {
          return false;
        }
      }
      return true;
    }
    if (a instanceof Number x && b instanceof Number y) {
      return x.doubleValue() == y.doubleValue();
    }
    return Objects.equals(a, b);
  }

  // ---- runs that span calls

  /** The SDK's refusal of a run id no store could hold, or one reserved for the pg_cron source. */
  static void checkRunId(String job, String id, String method) {
    if (id.isEmpty() || id.length() > 200) {
      throw CronwatchException.invalid(
          "job "
              + Json.quote(job)
              + ": "
              + method
              + "() needs a run id of 1 to 200 characters (got "
              + id.length()
              + " characters)");
    }
    if (id.startsWith(RESERVED_RUN_ID_PREFIX)) {
      throw CronwatchException.invalid(
          "job "
              + Json.quote(job)
              + ": "
              + method
              + "() cannot take a run id starting with "
              + Json.quote(RESERVED_RUN_ID_PREFIX)
              + ", which the pg_cron source uses for its runs");
    }
  }

  RunHandle startRun(JobDef def, StartOptions options) {
    String id = options.id;
    if (id == null) {
      return Core.awaitUninterruptibly(core.submit(() -> recordStart(def, options.trigger, null)));
    }
    checkRunId(def.name(), id, "start");
    // Keyed by job as well, so another job's start with the same id is not handed this job's
    // run: it fails as it would one call later.
    String key = def.name() + "\n" + id;
    CompletableFuture<RunHandle> mine = new CompletableFuture<>();
    CompletableFuture<RunHandle> shared = core.starting.putIfAbsent(key, mine);
    if (shared == null) {
      shared = mine;
      core.spawn(
          () -> {
            try {
              mine.complete(recordStart(def, options.trigger, id));
            } catch (Throwable t) {
              mine.completeExceptionally(t);
            } finally {
              core.starting.remove(key, mine);
            }
          },
          "starting " + def.name());
    }
    return Core.awaitUninterruptibly(shared);
  }

  /**
   * The start of a run without the function: the run is inserted and missed and stuck close. A
   * store that fails is reported and the handle inserts the finished run instead.
   */
  private RunHandle recordStart(JobDef def, String trigger, @Nullable String id) {
    String name = def.name();
    if (id != null) {
      Run stored = null;
      try {
        core.ensureReady();
        stored = Core.call(() -> core.store.getRun(id));
      } catch (RuntimeException e) {
        core.report(e, "recording " + name);
      }
      if (stored != null) {
        return existingHandle(def, stored);
      }
    }
    Run run =
        Run.running(id == null ? UUID.randomUUID().toString() : id, name, core.now(), trigger);
    boolean recorded;
    try {
      core.sync(def);
      Core.call(
          () -> {
            core.store.insertRun(run);
            return null;
          });
      recorded = true;
    } catch (RuntimeException e) {
      // Another process may have started a run with this id first.
      if (id != null) {
        Run stored = null;
        try {
          stored = Core.call(() -> core.store.getRun(id));
        } catch (RuntimeException ignored) {
          // Reported below as the start's failure.
        }
        if (stored != null) {
          return existingHandle(def, stored);
        }
      }
      core.report(e, "recording " + name);
      recorded = false;
    }
    if (recorded) {
      runs.closeOnStart(name);
    }
    return new RunHandle(core, runs, def, run.id(), run, recorded, null);
  }

  RunHandle resumeHandle(JobDef def, String runId) {
    checkRunId(def.name(), runId, "resume");
    return Core.awaitUninterruptibly(
        core.submit(
            () -> {
              Run stored;
              try {
                core.ensureReady();
                stored = Core.call(() -> core.store.getRun(runId));
              } catch (RuntimeException e) {
                core.report(e, "resuming " + def.name());
                return new RunHandle(core, runs, def, runId, null, true, null);
              }
              if (stored == null) {
                return new RunHandle(core, runs, def, runId, null, true, "was not found");
              }
              return existingHandle(def, stored);
            }));
  }

  /** A handle on a stored run. One still running, or marked timeout by a check, can be finished. */
  private RunHandle existingHandle(JobDef def, Run stored) {
    if (!stored.job().equals(def.name())) {
      throw CronwatchException.invalid(
          "run "
              + Json.quote(stored.id())
              + " belongs to job "
              + Json.quote(stored.job())
              + ", not "
              + Json.quote(def.name()));
    }
    boolean finished =
        stored.status().equals(RunStatus.OK) || stored.status().equals(RunStatus.FAILED);
    return new RunHandle(
        core,
        runs,
        def,
        stored.id(),
        stored,
        true,
        finished ? "already finished as " + stored.status() : null);
  }

  /**
   * A handle on a run started elsewhere, as {@code job(name).resume(runId)}. The job must be
   * declared in this process.
   *
   * @throws CronwatchException when the job is not declared, or for an invalid run id
   */
  public RunHandle resumeRun(String name, String runId) {
    JobDef def = core.declared(name);
    if (def == null) {
      throw CronwatchException.invalid(
          "resumeRun: job " + Json.quote(name) + " is not declared; call job first");
    }
    return resumeHandle(def, runId);
  }

  /**
   * Records a run that happened outside this process, for a {@link Source}. Its job must be
   * declared first. Runs are keyed by id: a new one is inserted, a stored one still running (or
   * marked timeout by a check) is finished when this one is not running, and anything else is left
   * alone, so recording the same run twice changes nothing. When two processes record the same
   * finish, only the one whose write lands evaluates it. A finished run is judged as if it had been
   * wrapped here, and its output and error are redacted the same way. Returns the alerts it sent.
   *
   * @throws CronwatchException when the job is not declared, or the store fails
   */
  public List<Alert> recordRun(Run run) {
    return recordRun(run, true);
  }

  /**
   * {@link #recordRun(Run)}, or with {@code evaluate} false, storing the run without judging it,
   * for history imported on first sight.
   *
   * @throws CronwatchException when the job is not declared, or the store fails
   */
  public List<Alert> recordRun(Run run, boolean evaluate) {
    return Core.awaitUninterruptibly(core.submit(() -> runs.recordRun(run, evaluate)));
  }

  // ---- checks and reads

  /**
   * Looks for missed and stuck runs across every job, sends alerts, retries alerts no channel
   * accepted, and prunes old runs. Call it from an interval ({@link #start}), a cron, or by hand.
   * Concurrent calls share one check. A job that cannot be evaluated is reported to the error
   * handler and shown as failing.
   *
   * @throws CronwatchException when the store fails as the check starts, or the caller is
   *     interrupted while it waits (its interrupt status set again)
   */
  public CheckResult check() {
    return checks.check();
  }

  /**
   * Every job the store knows about, with its health. Sends no alerts.
   *
   * @throws CronwatchException when the store fails
   */
  public List<JobSummary> jobs() {
    List<JobSummary> out = new ArrayList<>();
    for (JobWithRuns j : jobsWithRuns(0)) {
      out.add(j.job());
    }
    return out;
  }

  /**
   * Every job's summary with its newest {@code limit} runs (0 to 500), read together. What the
   * dashboard shows.
   *
   * @throws CronwatchException when the store fails
   */
  public List<JobWithRuns> jobsWithRuns(int limit) {
    return Core.awaitUninterruptibly(core.submit(() -> checks.jobsWithRuns(limit)));
  }

  /**
   * One job's summary, or null when the store does not know it.
   *
   * @throws CronwatchException when the store fails
   */
  public @Nullable JobSummary jobSummary(String name) {
    return Core.awaitUninterruptibly(core.submit(() -> checks.jobSummary(name)));
  }

  /**
   * A job's runs, newest first; {@code limit} is held from 1 to 500.
   *
   * @throws CronwatchException when the store fails
   */
  public List<Run> runs(String name, int limit) {
    return Core.awaitUninterruptibly(core.submit(() -> checks.runs(name, limit)));
  }

  /**
   * One run by its id, or null.
   *
   * @throws CronwatchException when the store fails
   */
  public @Nullable Run getRun(String id) {
    return Core.awaitUninterruptibly(core.submit(() -> checks.getRun(id)));
  }

  /**
   * Stops alerts for a job for a while, given as the SDK's text ({@code "2h"}). State keeps
   * updating underneath: nothing opens while it is silenced, so the first problem after the silence
   * alerts as usual.
   *
   * @throws CronwatchException for text that is not a duration, or when the store fails
   */
  public JobState silence(String name, String duration) {
    double ms;
    try {
      ms = Durations.parse(duration, "silence duration");
    } catch (IllegalArgumentException e) {
      throw CronwatchException.invalid(
          Objects.requireNonNullElse(e.getMessage(), "invalid duration"));
    }
    return silenceMs(name, ms);
  }

  /**
   * {@link #silence(String, String)} for a {@link Duration}.
   *
   * @throws CronwatchException when the store fails
   */
  public JobState silence(String name, Duration duration) {
    return silenceMs(name, JobOptions.millis(duration, "silence duration"));
  }

  private JobState silenceMs(String name, double ms) {
    return Core.awaitUninterruptibly(core.submit(() -> checks.silence(name, ms)));
  }

  /**
   * Ends a silence.
   *
   * @throws CronwatchException when the store fails
   */
  public JobState unsilence(String name) {
    return Core.awaitUninterruptibly(core.submit(() -> checks.unsilence(name)));
  }

  /**
   * Removes a job, its runs and its state from the store. A job still declared in code comes back
   * on its next run.
   *
   * @throws CronwatchException when the store fails
   */
  public void forget(String name) {
    Core.awaitUninterruptibly(
        core.submit(
            () -> {
              checks.forget(name);
              return null;
            }));
  }

  /**
   * Checks every minute, for a long-running service: the first check a second from now. Not for a
   * program a crontab runs once, which calls {@link #check} instead. A second {@code start} does
   * nothing.
   */
  public void start() {
    checks.start(60_000);
  }

  /** {@link #start()} on an interval: five seconds at least, at most 2^31 - 1 ms. */
  public void start(Duration every) {
    checks.start(JobOptions.millis(every, "check interval"));
  }

  /**
   * {@link #start()} on an interval given as the SDK's text ({@code "1m"}).
   *
   * @throws CronwatchException for text that is not a duration
   */
  public void start(String every) {
    try {
      checks.start(Durations.parse(every, "check interval"));
    } catch (IllegalArgumentException e) {
      throw CronwatchException.invalid(
          Objects.requireNonNullElse(e.getMessage(), "invalid duration"));
    }
  }

  /** Stops the interval {@link #start} began. A check in flight finishes. */
  public void stop() {
    checks.stop();
  }

  /**
   * Stops the interval, waits up to five seconds for sends and recordings in flight, then
   * interrupts what is left, removes the shutdown hook, and closes the store. A servlet container
   * or Spring context should call it when the app stops, so no thread of the client's holds the
   * app's class loader.
   */
  @Override
  public void close() {
    stop();
    if (shutdownHook != null) {
      try {
        Runtime.getRuntime().removeShutdownHook(shutdownHook);
      } catch (IllegalStateException e) {
        // The JVM is already stopping; the hook runs.
      }
    }
    core.timer.shutdownNow();
    core.executor.shutdown();
    try {
      if (!core.executor.awaitTermination(core.timings.closeWaitMs, TimeUnit.MILLISECONDS)) {
        core.executor.shutdownNow();
      }
    } catch (InterruptedException e) {
      core.executor.shutdownNow();
      Thread.currentThread().interrupt();
    }
    try {
      core.store.close();
    } catch (Exception e) {
      core.report(e, "closing the store");
    }
  }

  // ---- what a source uses

  /** Where this client keeps jobs, runs and state. */
  public Store store() {
    return core.store;
  }

  /** The client's clock, epoch milliseconds. */
  public long now() {
    return core.now();
  }

  /** The secret job handlers' requests must carry, or null. */
  public @Nullable String cronSecret() {
    return core.cronSecret;
  }

  /** Hands an error to the client's error handler, as the client reports its own. */
  public void reportError(Throwable error, String where) {
    core.report(error, where);
  }

  @Override
  public String toString() {
    return "Cronwatch[store=" + core.store + ", channels=" + core.channels.size() + "]";
  }

  /**
   * Makes a {@link Cronwatch}. Every option has the SDK's default. Not safe for use from several
   * threads at once.
   */
  public static final class Builder {
    private @Nullable Store store;
    private final List<Channel> channels = new ArrayList<>(List.of(new Console()));
    private boolean defaultChannels = true;
    private @Nullable Triage triage;
    private final List<Source> sources = new ArrayList<>();
    private boolean secretGiven;
    private @Nullable String cronSecret;
    private @Nullable Object retention = "30d";
    private @Nullable JobOptions defaults;
    private @Nullable UnaryOperator<String> redact;
    private boolean redactOff;
    private Deliver deliver = Deliver.NOW;
    private @Nullable ErrorHandler onError;
    private @Nullable LongSupplier clock;
    private boolean shutdownHook = true;
    final Core.Timings timings = new Core.Timings();

    private Builder() {}

    /**
     * Where jobs, runs and state live. The default is a {@link MemoryStore}, which forgets on
     * restart.
     */
    public Builder store(Store store) {
      this.store = Objects.requireNonNull(store, "store");
      return this;
    }

    /** Adds a channel alerts go to. The first call replaces the default console channel. */
    public Builder alert(Channel channel) {
      if (defaultChannels) {
        channels.clear();
        defaultChannels = false;
      }
      channels.add(Objects.requireNonNull(channel, "channel"));
      return this;
    }

    /** Where alerts go, replacing the default console channel. An empty list sends nowhere. */
    public Builder alerts(List<? extends Channel> channels) {
      this.channels.clear();
      this.channels.addAll(channels);
      defaultChannels = false;
      return this;
    }

    /** Adds a short diagnosis to every alert except recoveries. */
    public Builder triage(Triage triage) {
      this.triage = Objects.requireNonNull(triage, "triage");
      return this;
    }

    /**
     * Adds a source of runs this process does not wrap. Each is synced at the start of every check;
     * one that fails is reported and the check carries on.
     */
    public Builder source(Source source) {
      sources.add(Objects.requireNonNull(source, "source"));
      return this;
    }

    /**
     * The shared secret job handlers' requests must carry. The default is {@code $CRON_SECRET};
     * {@code ""} counts as unset.
     */
    public Builder cronSecret(String secret) {
      this.secretGiven = true;
      this.cronSecret = Objects.requireNonNull(secret, "secret");
      return this;
    }

    /** Lets job handlers run without a secret. */
    public Builder noCronSecret() {
      this.secretGiven = true;
      this.cronSecret = null;
      return this;
    }

    /** How long finished runs are kept, as the SDK's text. Default {@code "30d"}. */
    public Builder retention(String duration) {
      this.retention = Objects.requireNonNull(duration, "duration");
      return this;
    }

    /** How long finished runs are kept. */
    public Builder retention(Duration duration) {
      this.retention = JobOptions.millis(duration, "retention");
      return this;
    }

    /**
     * Grace, timeout, timezone and failures before alert for every job that does not set its own.
     * {@link #build} refuses any other option.
     */
    public Builder defaults(JobOptions defaults) {
      this.defaults = defaults.copy();
      return this;
    }

    /**
     * Replaces the default redaction of every run's output and error before it is stored, shown or
     * sent anywhere. A function that throws or answers null is reported ({@code redact}) and the
     * default is used.
     */
    public Builder redact(UnaryOperator<String> redact) {
      this.redact = Objects.requireNonNull(redact, "redact");
      this.redactOff = false;
      return this;
    }

    /** Keeps output and errors exactly as logged. */
    public Builder noRedaction() {
      this.redact = null;
      this.redactOff = true;
      return this;
    }

    /**
     * Where alerts are sent from: {@link Deliver#NOW} (the default) or {@link Deliver#AT_CHECK}.
     */
    public Builder deliver(Deliver deliver) {
      this.deliver = Objects.requireNonNull(deliver, "deliver");
      return this;
    }

    /** Called with anything that goes wrong outside a job. See {@link ErrorHandler}. */
    public Builder onError(ErrorHandler onError) {
      this.onError = Objects.requireNonNull(onError, "onError");
      return this;
    }

    /** Replaces the clock, epoch milliseconds. Tests use it. */
    public Builder clock(LongSupplier clock) {
      this.clock = Objects.requireNonNull(clock, "clock");
      return this;
    }

    /**
     * Leaves out the shutdown hook, which otherwise marks runs still open in this JVM failed
     * ({@code Shutdown: the JVM stopped while the run was in progress}) when the JVM begins to
     * stop, within five seconds.
     */
    public Builder noShutdownHook() {
      this.shutdownHook = false;
      return this;
    }

    /**
     * Makes the client.
     *
     * @throws CronwatchException for an option the SDK refuses
     */
    public Cronwatch build() {
      JsObject defaultFields = new JsObject();
      if (defaults != null) {
        for (String key : defaults.fields.keys()) {
          if (!DEFAULTABLE.contains(key)) {
            throw CronwatchException.invalid(
                "defaults takes grace, timeout, timezone and failuresBeforeAlert, not " + key);
          }
        }
        if (defaults.expect != null) {
          throw CronwatchException.invalid(
              "defaults takes grace, timeout, timezone and failuresBeforeAlert, not expect");
        }
        defaultFields = defaults.fields.copy();
      }
      double retentionMs;
      try {
        retentionMs = Durations.parseValue(retention, "retention");
      } catch (IllegalArgumentException e) {
        throw CronwatchException.invalid(Objects.requireNonNullElse(e.getMessage(), "retention"));
      }
      String secret = secretGiven ? cronSecret : Env.read("CRON_SECRET");
      boolean optOut = secretGiven && cronSecret == null;
      ErrorHandler handler =
          onError != null
              ? onError
              : (where, error) ->
                  Env.LOGGER.log(
                      System.Logger.Level.ERROR,
                      "[cronwatch] "
                          + where
                          + ": "
                          + Objects.requireNonNullElse(
                              error.getMessage(), error.getClass().getName()),
                      error);
      Core core =
          new Core(
              store == null ? new MemoryStore() : store,
              store == null,
              channels,
              triage,
              sources,
              secret == null || secret.isEmpty() ? null : secret,
              optOut,
              retentionMs,
              defaultFields,
              redact,
              redactOff,
              deliver == Deliver.AT_CHECK,
              handler,
              clock == null ? System::currentTimeMillis : clock,
              timings);
      return new Cronwatch(core, shutdownHook);
    }

    /** Names what is set, never a secret's value. */
    @Override
    public String toString() {
      return "Cronwatch.Builder[store="
          + (store == null ? "memory" : store.toString())
          + ", channels="
          + channels.size()
          + ", cronSecret="
          + (secretGiven ? (cronSecret == null ? "none" : "set") : "from CRON_SECRET")
          + "]";
    }
  }
}
