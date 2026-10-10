package dev.cronwatch.pgcron;

import dev.cronwatch.Alert;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.CronwatchException;
import dev.cronwatch.Definition;
import dev.cronwatch.JobOptions;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.Source;
import dev.cronwatch.StoredJob;
import dev.cronwatch.internal.evaluate.Format;
import dev.cronwatch.internal.js.Js;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.concurrent.locks.ReentrantLock;
import org.jspecify.annotations.Nullable;

/**
 * The pg_cron source: {@code sources/pgcron.ts}'s {@code pgCron()}, with where it is between checks
 * (each job's cursor, the runs still going, the runs held before they start, the names declared)
 * held here, so it ends with the source, and a new source finds its place again from the store.
 */
final class PgCronSource implements Source {
  /** How many of a job's newest runs are copied, without alerting, the first time it is seen. */
  private static final int BACKFILL = 20;

  /** Run details read per query, and the most queries one sync makes. */
  private static final int PAGE = 500;

  private static final int MAX_PAGES = 10;

  static final String JOBS_SQL =
      "SELECT jobid, jobname, schedule, database, username, active FROM cron.job ORDER BY jobid";

  /**
   * pg_settings has no row for a setting the role may not read, where current_setting() raises an
   * error that would abort the caller's transaction.
   */
  static final String SETTING_SQL = "SELECT setting FROM pg_settings WHERE name = ?";

  private static final String COLUMNS =
      "d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time";

  /**
   * Every tracked job's runs after its cursor, and any run still open here, whatever its job. The
   * arrays are passed as array literals in text, which every driver can send.
   */
  static final String RUNS_SQL =
      "SELECT "
          + COLUMNS
          + "\n  FROM cron.job_run_details d\n"
          + "  LEFT JOIN unnest(?::text::bigint[], ?::text::bigint[]) AS c(jobid, after) ON d.jobid"
          + " = c.jobid\n"
          + "  WHERE d.runid > c.after OR d.runid = ANY(?::text::bigint[])\n"
          + "  ORDER BY d.runid LIMIT "
          + PAGE;

  static final String NEWEST_SQL =
      "SELECT "
          + COLUMNS
          + " FROM cron.job_run_details d WHERE d.jobid = ? ORDER BY d.runid DESC LIMIT "
          + BACKFILL;

  private final PgCron.Query db;
  private final PgCronOptions o;
  private final String idPrefix;
  private final ReentrantLock lock = new ReentrantLock();

  /** The newest runid read for each jobid, once known. */
  private final Map<Long, Long> cursors = new HashMap<>();

  /** The start of the newest run copied for each jobid: where a restart row with no times goes. */
  private final Map<Long, Long> lastAt = new HashMap<>();

  /**
   * Runs copied while still going, by runid, with their job: read again until they finish, even
   * once a check marks them timeout.
   */
  private final Map<Long, String> pending = new HashMap<>();

  /** Runs read before they started, by runid, with when they were first seen. */
  private final Map<Long, Long> held = new HashMap<>();

  /** Each job's name and definition as last declared, by jobid. */
  private Map<Long, Declared> known = new TreeMap<>();

  /** The last definition declared for each name, so an unchanged job is not declared again. */
  private final Map<String, String> declared = new HashMap<>();

  /** Names declared again without a schedule by retire(), whose open runs are still read. */
  private final Set<String> retired = new HashSet<>();

  private boolean scanned;
  private final Set<String> warned = new HashSet<>();

  /** Jobids whose callback failed, reported once until it works again. */
  private final Set<Long> failing = new HashSet<>();

  /** A job as last declared: its name and the definition its options gave. */
  private record Declared(String name, Definition definition) {}

  PgCronSource(PgCron.Query db, PgCronOptions options) {
    this.db = db;
    this.o = options;
    this.idPrefix = "pgcron:" + options.prefix;
  }

  @Override
  public String name() {
    return "pg_cron";
  }

  /** Names the options set, never the data source. */
  @Override
  public String toString() {
    return "PgCron.source(" + o + ")";
  }

  private void warnOnce(Cronwatch host, String key, String message) {
    if (warned.add(key)) {
      host.reportError(
          new CronwatchException(CronwatchException.Kind.OTHER, message), "source pg_cron");
    }
  }

  /**
   * A callback of the app's (pick, jobName, options) that threw, or a jobName that gave no name,
   * fails only its job, as a bad row does: reported once until it works again, and the job carries
   * on as last declared (skipped when it never was), so its runs are still copied.
   */
  private void trouble(
      Cronwatch host,
      PgCronJob job,
      String what,
      Map<Long, String> names,
      Map<Long, Definition> definitions,
      Set<String> used) {
    if (failing.add(job.jobId())) {
      host.reportError(
          new CronwatchException(
              CronwatchException.Kind.OTHER,
              "pg_cron job "
                  + job.jobId()
                  + ": "
                  + what
                  + "; it keeps its last declaration until that works"),
          "source pg_cron");
    }
    Declared last = known.get(job.jobId());
    if (last == null || used.contains(last.name())) {
      return;
    }
    names.put(job.jobId(), last.name());
    definitions.put(job.jobId(), last.definition());
    used.add(last.name());
  }

  /**
   * What a callback threw, as the SDK names an error: its class's simple name, then its message.
   */
  private static String threw(RuntimeException e) {
    Class<?> type = e.getClass();
    String name = type.getSimpleName().isEmpty() ? type.getName() : type.getSimpleName();
    String message = e.getMessage();
    return name + ": " + (message == null ? "" : message);
  }

  private boolean picks(PgCronJob job) {
    if (o.pick != null) {
      return o.pick.test(job);
    }
    if (o.jobs == null && o.jobIds == null) {
      return true;
    }
    if (o.jobIds != null && o.jobIds.contains(job.jobId())) {
      return true;
    }
    return o.jobs != null && job.jobName() != null && o.jobs.contains(job.jobName());
  }

  /** A server setting from pg_settings, or null when the role may not read it (or it failed). */
  private @Nullable String setting(String name) {
    try {
      List<Map<String, @Nullable Object>> rows = db.query(SETTING_SQL, List.of(name));
      return rows.isEmpty() ? null : PgCron.text(rows.get(0).get("setting"));
    } catch (Exception e) {
      return null;
    }
  }

  /** The pg_cron runid of a run id this source made ({@code Number()} of the rest), or null. */
  private @Nullable Long runIdOf(String id) {
    if (!id.startsWith(idPrefix)) {
      return null;
    }
    String rest = Js.trim(id.substring(idPrefix.length()));
    if (rest.isEmpty()) {
      return 0L;
    }
    // A decimal number only: Number() takes neither Java's type suffixes nor its hexadecimal
    // floats, and no id this source made has anything else.
    for (int i = 0; i < rest.length(); i++) {
      char c = rest.charAt(i);
      if (!(c >= '0' && c <= '9') && c != '.' && c != 'e' && c != 'E' && c != '+' && c != '-') {
        return null;
      }
    }
    double n;
    try {
      n = Double.parseDouble(rest);
    } catch (NumberFormatException e) {
      return null;
    }
    return Js.isInteger(n) && Math.abs(n) <= Js.MAX_SAFE_INTEGER ? (long) n : null;
  }

  private static String keyOf(Definition definition) {
    return definition.toJson();
  }

  /**
   * The options of a declared or stored definition that can be declared again, without its
   * schedule, in the SDK's order: description, tags, grace, timeout, maxDuration, budget, floor,
   * and failuresBeforeAlert.
   */
  private static JobOptions unscheduled(Definition definition) {
    JobOptions out = JobOptions.builder();
    for (String key :
        List.of(
            "description",
            "tags",
            "grace",
            "timeout",
            "maxDuration",
            "budget",
            "floor",
            "failuresBeforeAlert")) {
      if (definition.has(key)) {
        out.field(key, definition.get(key));
      }
    }
    return out;
  }

  /** Declares a name this source no longer uses for any job again, without its schedule. */
  private void retire(Cronwatch host, String name, Definition definition, String why) {
    JobOptions next = unscheduled(definition);
    Object description = definition.get("description");
    next.field(
        "description",
        (description == null ? "pg_cron job" : Format.jsText(description)) + " (" + why + ")");
    try {
      host.job(name, next);
      declared.put(name, keyOf(next.describe(name)));
      retired.add(name);
    } catch (RuntimeException e) {
      host.reportError(e, "source pg_cron: job " + name);
    }
  }

  @Override
  public List<Alert> sync(Cronwatch host) throws Exception {
    lock.lock();
    try {
      return syncLocked(host);
    } finally {
      lock.unlock();
    }
  }

  private List<Alert> syncLocked(Cronwatch host) throws Exception {
    long now = host.now();
    String timezone = o.timezone;
    if (timezone.isEmpty()) {
      String tz = setting("cron.timezone");
      if (tz == null) {
        warnOnce(
            host,
            "tz",
            "could not read cron.timezone; assuming UTC. Grant pg_read_all_settings or pass"
                + " PgCronOptions.builder().timezone(...).");
      }
      timezone = tz == null || isUtc(tz) ? "UTC" : tz;
    }
    String logRun = setting("cron.log_run");
    boolean recording = !"off".equals(logRun);
    if (!recording) {
      warnOnce(
          host,
          "log_run",
          "cron.log_run is off, so pg_cron records no runs: jobs are watched without their"
              + " schedules and no run can fail. Turn it on to watch them.");
    }

    List<Map<String, @Nullable Object>> rows = db.query(JOBS_SQL, List.of());
    if (rows.isEmpty()) {
      warnOnce(
          host,
          "empty",
          "cron.job shows no jobs. pg_cron's row level security shows a role only the jobs it"
              + " scheduled: connect as that role, or give this one BYPASSRLS.");
    }
    List<PgCronJob> all = new ArrayList<>();
    for (Map<String, @Nullable Object> r : rows) {
      all.add(PgCron.jobOf(r));
    }

    // Declare each job. A paused one (active = false) keeps its failures but loses its schedule,
    // so it is not missed. One forgotten since it was declared (the dashboard's forget) is declared
    // again, though unchanged: recordRun takes runs only of a declared job.
    Set<String> live = new HashSet<>();
    for (Definition d : host.definedJobs()) {
      live.add(d.name());
    }
    Map<Long, String> names = new LinkedHashMap<>();
    Map<Long, Definition> definitions = new HashMap<>();
    Set<String> used = new HashSet<>();
    for (PgCronJob job : all) {
      boolean picked;
      try {
        picked = picks(job);
      } catch (RuntimeException e) {
        trouble(host, job, "the jobs callback threw " + threw(e), names, definitions, used);
        continue;
      }
      if (!picked) {
        failing.remove(job.jobId());
        continue;
      }
      @Nullable String given;
      try {
        given = o.jobName != null ? o.jobName.apply(job) : PgCron.jobName(job);
      } catch (RuntimeException e) {
        trouble(host, job, "jobName threw " + threw(e), names, definitions, used);
        continue;
      }
      if (given == null) {
        trouble(host, job, "jobName returned null, not a name", names, definitions, used);
        continue;
      }
      @Nullable JobOptions asked;
      try {
        asked = o.options == null ? null : o.options.apply(job);
      } catch (RuntimeException e) {
        trouble(host, job, "the options callback threw " + threw(e), names, definitions, used);
        continue;
      }
      failing.remove(job.jobId());
      String name = o.prefix + given;
      if (used.contains(name)) {
        name = name + ":" + job.jobId();
      }
      used.add(name);
      try {
        JobOptions extra = asked == null ? JobOptions.builder() : asked.copy();
        if (PgCronOptions.fromPgCron(extra.describe(name))) {
          throw CronwatchException.invalid(
              "PgCronOptions: options may not set a schedule or timezone; they come from pg_cron");
        }
        String schedule = job.active() && recording ? PgCron.schedule(job.schedule()) : null;
        JobOptions base =
            JobOptions.builder()
                .description(
                    "pg_cron job "
                        + job.jobId()
                        + " in "
                        + job.database()
                        + " as "
                        + job.username()
                        + (job.active() ? "" : " (paused)"))
                .tags("pg_cron")
                .merge(extra);
        JobOptions options =
            schedule == null ? base : base.copy().schedule(schedule).timezone(timezone);
        Definition definition = options.describe(name);
        String key = keyOf(definition);
        if (!key.equals(declared.get(name)) || !live.contains(name)) {
          try {
            host.job(name, options);
          } catch (CronwatchException e) {
            if (schedule == null) {
              throw e;
            }
            // A schedule CronWatch cannot read: watch the runs, not the cadence.
            host.reportError(
                new CronwatchException(
                    CronwatchException.Kind.OTHER,
                    "pg_cron job "
                        + job.jobId()
                        + ": "
                        + e.getMessage()
                        + "; watching it without a schedule"),
                "source pg_cron");
            definition = base.describe(name);
            host.job(name, base);
          }
          declared.put(name, key);
        }
        names.put(job.jobId(), name);
        definitions.put(job.jobId(), definition);
      } catch (RuntimeException e) {
        host.reportError(e, "source pg_cron: job " + job.jobId());
      }
    }

    // A name this source used for a job that has since been renamed, unscheduled, or dropped from
    // the jobs picked.
    Set<String> inUse = new HashSet<>(names.values());
    retired.removeAll(inUse);
    for (Map.Entry<Long, Declared> e : known.entrySet()) {
      Declared previous = e.getValue();
      if (inUse.contains(previous.name())) {
        continue;
      }
      String renamed = names.get(e.getKey());
      retire(
          host,
          previous.name(),
          previous.definition(),
          renamed != null ? "renamed to " + renamed : "no longer watched");
    }
    Map<Long, Declared> nowKnown = new TreeMap<>();
    for (Map.Entry<Long, String> e : names.entrySet()) {
      nowKnown.put(e.getKey(), new Declared(e.getValue(), definitions.get(e.getKey())));
    }
    known = nowKnown;
    // Once per source, the same for names left scheduled in the store while nothing was watching.
    if (!scanned && !rows.isEmpty()) {
      scanned = true;
      scan(host, all, names, inUse);
    }
    if (!recording || names.isEmpty()) {
      return List.of();
    }

    List<Alert> alerts = new ArrayList<>();
    // The names a run may be recorded under: this sync's, and those the client declares now, after
    // the retires above. A run copied under a retired name that was then forgotten (the
    // dashboard's forget) has no job to go to: it is let go, never recorded, and never read again.
    Set<String> recordable = new HashSet<>(inUse);
    for (Definition d : host.definedJobs()) {
      recordable.add(d.name());
    }

    // Where each job left off. Found from the store the first time, so a restart carries on.
    for (Map.Entry<Long, String> e : names.entrySet()) {
      long jobId = e.getKey();
      String name = e.getValue();
      if (cursors.containsKey(jobId)) {
        continue;
      }
      List<Run> ours = new ArrayList<>();
      for (Run r : host.store().listRuns(name, BACKFILL)) {
        if (runIdOf(r.id()) != null) {
          ours.add(r);
        }
      }
      if (!ours.isEmpty()) {
        long cursor = Long.MIN_VALUE;
        long last = Long.MIN_VALUE;
        for (Run r : ours) {
          long id = Objects.requireNonNull(runIdOf(r.id()));
          cursor = Math.max(cursor, id);
          last = Math.max(last, r.startedAt());
          if (r.status().equals(RunStatus.RUNNING) || r.status().equals(RunStatus.TIMEOUT)) {
            pending.put(id, r.job());
          }
        }
        cursors.put(jobId, cursor);
        lastAt.put(jobId, last);
        continue;
      }
      // First sight: copy recent history quietly, and judge only from the newest finished run
      // on. The cursor goes to the newest row read, whatever is held, so history is never judged
      // later.
      List<PgCronRow> ordered = new ArrayList<>();
      for (Map<String, @Nullable Object> r : db.query(NEWEST_SQL, List.of(jobId))) {
        ordered.add(PgCron.rowOf(r));
      }
      Collections.reverse(ordered);
      int lastFinished = -1;
      for (int i = 0; i < ordered.size(); i++) {
        if (PgCron.finished(ordered.get(i).status())) {
          lastFinished = i;
        }
      }
      for (int i = 0; i < ordered.size(); i++) {
        PgCronRow row = ordered.get(i);
        // Already copied under another name (the job was renamed while nothing watched): left.
        if (host.store().getRun(idPrefix + row.runId()) != null) {
          continue;
        }
        record(host, names, recordable, row, i >= lastFinished, now, alerts);
      }
      cursors.put(jobId, ordered.isEmpty() ? 0 : ordered.get(ordered.size() - 1).runId());
    }

    // New runs, runs copied while still going (or since marked timeout), and runs not yet
    // started.
    Set<String> watched = new HashSet<>(names.values());
    watched.addAll(retired);
    for (Run run : host.store().runningRuns()) {
      Long id = runIdOf(run.id());
      if (id != null && watched.contains(run.job())) {
        pending.put(id, run.job());
      }
    }
    Set<Long> open = new TreeSet<>(pending.keySet());
    open.addAll(held.keySet());
    boolean complete = false;
    for (int page = 0; page < MAX_PAGES; page++) {
      List<Long> jobIds = new ArrayList<>(names.keySet());
      List<Long> afters = new ArrayList<>();
      for (long jobId : jobIds) {
        afters.add(cursors.getOrDefault(jobId, 0L));
      }
      List<Map<String, @Nullable Object>> found =
          db.query(RUNS_SQL, List.of(arrayOf(jobIds), arrayOf(afters), arrayOf(open)));
      for (Map<String, @Nullable Object> r : found) {
        PgCronRow row = PgCron.rowOf(r);
        open.remove(row.runId());
        record(host, names, recordable, row, true, now, alerts);
        // Held or not, the cursor moves on: a held run is read again by its runid.
        if (names.containsKey(row.jobId()) && row.runId() > cursors.getOrDefault(row.jobId(), 0L)) {
          cursors.put(row.jobId(), row.runId());
        }
      }
      if (found.size() < PAGE) {
        complete = true;
        break;
      }
    }
    // Every row was read and these were not among them: pg_cron no longer has them.
    if (complete) {
      for (long runId : open) {
        pending.remove(runId);
        held.remove(runId);
      }
    }
    return alerts;
  }

  /** cron.timezone's value that is UTC by another name: {@code /^(gmt|utc|z)$/i}. */
  private static boolean isUtc(String tz) {
    String t = tz.length() <= 3 ? tz.toLowerCase(java.util.Locale.ROOT) : "";
    return t.equals("gmt") || t.equals("utc") || t.equals("z");
  }

  /**
   * Names this source's kind left scheduled in the store while nothing was watching: one whose job
   * is gone from cron.job, or was renamed, is declared again without its schedule.
   */
  private void scan(
      Cronwatch host, List<PgCronJob> all, Map<Long, String> names, Set<String> inUse) {
    try {
      Set<Long> visible = new HashSet<>();
      for (PgCronJob j : all) {
        visible.add(j.jobId());
      }
      for (StoredJob stored : host.store().listJobs()) {
        Definition def = stored.definition();
        String schedule = def.get("schedule") instanceof String s ? s : "";
        if (!stored.name().startsWith(o.prefix)
            || inUse.contains(stored.name())
            || schedule.isEmpty()
            || !def.tags().contains("pg_cron")) {
          continue;
        }
        Long jobId = describedJobId(def.get("description"));
        if (jobId == null) {
          continue;
        }
        String current = names.get(jobId);
        if (!visible.contains(jobId)) {
          retire(host, stored.name(), def, "no longer in cron.job");
        } else if (current != null
            // Another pg_cron source's name for the same job ends the same way: left alone.
            && !stored.name().endsWith(current.substring(o.prefix.length()))) {
          retire(host, stored.name(), def, "renamed to " + current);
        }
      }
    } catch (Exception e) {
      host.reportError(e, "source pg_cron");
    }
  }

  /** The jobid a description this source wrote names ({@code /^pg_cron job (\d+) in /}). */
  private static @Nullable Long describedJobId(@Nullable Object description) {
    if (!(description instanceof String d) || !d.startsWith("pg_cron job ")) {
      return null;
    }
    int start = "pg_cron job ".length();
    int i = start;
    while (i < d.length() && d.charAt(i) >= '0' && d.charAt(i) <= '9') {
      i++;
    }
    if (i == start || !d.startsWith(" in ", i)) {
      return null;
    }
    // Number() of the digits: past a long they are no jobid pg_cron has.
    try {
      return Long.parseLong(d.substring(start, i));
    } catch (NumberFormatException e) {
      return null;
    }
  }

  /**
   * Copies one row. A row that cannot be recorded is reported and skipped; it never stops the
   * others.
   */
  private void record(
      Cronwatch host,
      Map<Long, String> names,
      Set<String> recordable,
      PgCronRow row,
      boolean evaluate,
      long now,
      List<Alert> alerts) {
    long runId = row.runId();
    long jobId = row.jobId();
    String name = pending.containsKey(runId) ? pending.get(runId) : names.get(jobId);
    if (name == null || !recordable.contains(name)) {
      pending.remove(runId);
      held.remove(runId);
      if (name != null) {
        retired.remove(name);
      }
      return;
    }
    Run run;
    if (row.startTime() == null && !PgCron.finished(row.status())) {
      long since = held.getOrDefault(runId, now);
      if (now - since < PgCron.HOLD_MS) {
        held.put(runId, since);
        return;
      }
      run =
          PgCron.run(
              new PgCronRow(runId, jobId, row.status(), row.returnMessage(), since, row.endTime()),
              name,
              idPrefix,
              now);
    } else {
      run = PgCron.run(row, name, idPrefix, lastAt.getOrDefault(jobId, now));
    }
    held.remove(runId);
    if (run == null) {
      return;
    }
    try {
      alerts.addAll(host.recordRun(run, evaluate));
    } catch (RuntimeException e) {
      host.reportError(e, "source pg_cron: run " + runId);
      return;
    }
    if (run.status().equals(RunStatus.RUNNING)) {
      pending.put(runId, name);
    } else {
      pending.remove(runId);
    }
    Long last = lastAt.get(jobId);
    if (last == null || run.startedAt() > last) {
      lastAt.put(jobId, run.startedAt());
    }
  }

  /** A Postgres array literal, {@code {1,2,3}}. */
  static String arrayOf(Iterable<Long> ids) {
    StringBuilder b = new StringBuilder("{");
    for (long id : ids) {
      if (b.length() > 1) {
        b.append(',');
      }
      b.append(id);
    }
    return b.append('}').toString();
  }
}
