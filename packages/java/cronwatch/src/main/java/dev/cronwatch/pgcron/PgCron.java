package dev.cronwatch.pgcron;

import dev.cronwatch.Metrics;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.Source;
import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.internal.js.Js;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import javax.sql.DataSource;
import org.jspecify.annotations.Nullable;

/**
 * Watches pg_cron jobs, which run inside Postgres where nothing can wrap them: the SDK's {@code
 * pgCron()} source ({@code sources/pgcron.ts}), line for line as the Go, Rust, and Elixir ports
 * have it. As a source, on every check it reads {@code cron.job} and declares each job with its
 * schedule, then copies new rows of {@code cron.job_run_details} in as runs (ids {@code
 * pgcron:<prefix><runid>}), so the usual evaluation raises missed, failed, stuck, and slow alerts.
 *
 * <pre>{@code
 * Cronwatch cw = Cronwatch.builder()
 *     .store(SqlStore.postgres(dataSource))
 *     .source(PgCron.source(dataSource, PgCronOptions.builder().prefix("db:").build()))
 *     .build();
 * cw.startChecking();
 * }</pre>
 *
 * <p>A job that is renamed, unscheduled, or no longer picked keeps its old name's runs and history,
 * and that name is declared again without a schedule, so it is never reported missed. Its
 * description says why.
 *
 * <p>The data source must reach the database pg_cron runs in (its {@code cron.database_name}). Each
 * query runs on a connection of its own, taken from the data source for it, so the source never
 * reads inside a transaction the app has open, and it never commits or rolls back anything.
 * Settings are read from {@code pg_settings}, which answers no row for a setting the role may not
 * read, where {@code current_setting()} would raise an error.
 */
public final class PgCron {
  private PgCron() {}

  /**
   * How long a run pg_cron has queued but not started (no start time yet) is waited for: ten
   * minutes. After that it is copied as running from when it was first seen, so a run that never
   * starts is marked stuck like any other.
   */
  static final long HOLD_MS = 10 * 60_000L;

  /** One query, answering its rows, each a map of lowercase column name to value. */
  @FunctionalInterface
  interface Query {
    List<Map<String, @Nullable Object>> query(String sql, List<Object> params) throws Exception;
  }

  /** A source watching every job the data source's role can see. */
  public static Source source(DataSource dataSource) {
    return source(dataSource, PgCronOptions.defaults());
  }

  /** A source watching the jobs {@code options} picks. */
  public static Source source(DataSource dataSource, PgCronOptions options) {
    Objects.requireNonNull(dataSource, "dataSource");
    Objects.requireNonNull(options, "options");
    return new PgCronSource((sql, params) -> query(dataSource, sql, params), options);
  }

  /** A source over any query function: the SDK's {@code Queryable}, for the tests' fake. */
  static Source source(Query query, PgCronOptions options) {
    return new PgCronSource(query, options);
  }

  /**
   * Runs a query on a connection of its own, in autocommit, and reads every row. Times come back as
   * epoch milliseconds, numbers as they are, anything else as text.
   */
  private static List<Map<String, @Nullable Object>> query(
      DataSource dataSource, String sql, List<Object> params) throws SQLException {
    try (Connection c = dataSource.getConnection()) {
      if (!c.getAutoCommit()) {
        c.setAutoCommit(true);
      }
      try (PreparedStatement ps = c.prepareStatement(sql)) {
        for (int i = 0; i < params.size(); i++) {
          Object p = params.get(i);
          if (p instanceof Long n) {
            ps.setLong(i + 1, n);
          } else {
            ps.setString(i + 1, String.valueOf(p));
          }
        }
        try (ResultSet rs = ps.executeQuery()) {
          ResultSetMetaData meta = rs.getMetaData();
          int n = meta.getColumnCount();
          List<Map<String, @Nullable Object>> rows = new ArrayList<>();
          while (rs.next()) {
            Map<String, @Nullable Object> row = new HashMap<>();
            for (int i = 1; i <= n; i++) {
              Object v = rs.getObject(i);
              if (v instanceof Timestamp t) {
                v = t.getTime();
              } else if (v != null
                  && !(v instanceof Number)
                  && !(v instanceof Boolean)
                  && !(v instanceof String)) {
                v = rs.getString(i);
              }
              row.put(meta.getColumnLabel(i).toLowerCase(Locale.ROOT), v);
            }
            rows.add(row);
          }
          return rows;
        }
      }
    }
  }

  // ---- the SDK's helpers

  /**
   * A pg_cron schedule as a CronWatch one ({@code pgCronSchedule}): a cron expression, {@code $}
   * for the last day of the month read as {@code L}, or {@code N seconds} as {@code every Ns}.
   * pg_cron reads only the first five fields of an expression and ignores the rest, so only those
   * are kept (a sixth would otherwise be read as seconds). Null for one that has no cadence to
   * watch ({@code @reboot}).
   */
  static @Nullable String schedule(String schedule) {
    String text = Js.trim(schedule);
    String seconds = seconds(text);
    if (seconds != null) {
      return "every " + Js.formatNumber(Double.parseDouble(seconds)) + "s";
    }
    if (asciiLower(text).equals("@reboot")) {
      return null;
    }
    List<String> fields = split(text);
    if (fields.size() > 5 && !fields.get(0).startsWith("@")) {
      fields = new ArrayList<>(fields.subList(0, 5));
    }
    if (fields.size() == 5 && fields.get(2).contains("$")) {
      fields.set(2, fields.get(2).replace("$", "L"));
    }
    return String.join(" ", fields);
  }

  /** The digits of {@code /^(\d+)\s*seconds?$/i}, or null when the text is not that. */
  private static @Nullable String seconds(String text) {
    int i = 0;
    while (i < text.length() && text.charAt(i) >= '0' && text.charAt(i) <= '9') {
      i++;
    }
    if (i == 0) {
      return null;
    }
    int j = i;
    while (j < text.length() && Js.isSpace(text.charAt(j))) {
      j++;
    }
    String rest = asciiLower(text.substring(j));
    return rest.equals("second") || rest.equals("seconds") ? text.substring(0, i) : null;
  }

  /** Lowercases ASCII letters only, as {@code /i} without the {@code u} flag folds them. */
  private static String asciiLower(String s) {
    StringBuilder b = new StringBuilder(s.length());
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      b.append(c >= 'A' && c <= 'Z' ? (char) (c + 32) : c);
    }
    return b.toString();
  }

  /** {@code text.split(/\s+/)} of text already trimmed: {@code ""} is {@code [""]}. */
  private static List<String> split(String text) {
    List<String> out = new ArrayList<>();
    StringBuilder field = new StringBuilder();
    for (int i = 0; i < text.length(); i++) {
      char c = text.charAt(i);
      if (Js.isSpace(c)) {
        if (!field.isEmpty()) {
          out.add(field.toString());
          field.setLength(0);
        }
      } else {
        field.append(c);
      }
    }
    out.add(field.toString());
    return out;
  }

  /**
   * The default CronWatch name for a pg_cron job, before the prefix ({@code pgCronJobName}): its
   * jobname with each run of anything other than letters, digits, {@code .}, {@code _}, {@code :},
   * and {@code -} turned into {@code -}, what leads up to the first letter or digit dropped, at
   * most 100 characters, or {@code pg_cron:<jobid>} when nothing is left.
   */
  static String jobName(PgCronJob job) {
    String name = job.jobName() == null ? "" : job.jobName();
    StringBuilder cleaned = new StringBuilder();
    boolean inRun = false;
    for (int i = 0; i < name.length(); i++) {
      char c = name.charAt(i);
      if (alnum(c) || c == '.' || c == '_' || c == ':' || c == '-') {
        cleaned.append(c);
        inRun = false;
      } else if (!inRun) {
        cleaned.append('-');
        inRun = true;
      }
    }
    int start = 0;
    while (start < cleaned.length() && !alnum(cleaned.charAt(start))) {
      start++;
    }
    String out = cleaned.substring(start, Math.min(cleaned.length(), start + 100));
    return out.isEmpty() ? "pg_cron:" + job.jobId() : out;
  }

  private static boolean alnum(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
  }

  static boolean finished(@Nullable String status) {
    return "succeeded".equals(status) || "failed".equals(status);
  }

  /**
   * A row of {@code cron.job_run_details} as a CronWatch run ({@code pgCronRun}), or null for one
   * that has not started (no start time, not finished). A finished row with no start time (pg_cron
   * writes these for runs a server restart cut off, "server restarted") starts at its end time,
   * else at {@code fallbackAt} (the source passes the job's newest run's start, or now).
   */
  static @Nullable Run run(PgCronRow row, String job, String idPrefix, long fallbackAt) {
    Long finishedAt = row.endTime();
    boolean done = finished(row.status());
    if (row.startTime() == null && !done) {
      return null;
    }
    long startedAt =
        row.startTime() != null ? row.startTime() : finishedAt != null ? finishedAt : fallbackAt;
    String message = null;
    if (row.returnMessage() != null) {
      String trimmed = Js.trim(row.returnMessage());
      message = trimmed.isEmpty() ? null : trimmed;
    }
    RunStatus status =
        "succeeded".equals(row.status())
            ? RunStatus.OK
            : "failed".equals(row.status()) ? RunStatus.FAILED : RunStatus.RUNNING;
    Long end = done ? Math.max(startedAt, finishedAt == null ? startedAt : finishedAt) : null;
    return new Run(
        idPrefix + row.runId(),
        job,
        status,
        startedAt,
        end,
        end == null ? null : Evaluate.runDuration(startedAt, end),
        status.equals(RunStatus.FAILED)
            ? (message == null ? "pg_cron reported the run as failed" : message)
            : null,
        status.equals(RunStatus.OK) ? message : null,
        Metrics.empty(),
        "pg_cron");
  }

  // ---- reading values as a driver or a fake gives them

  static @Nullable String text(@Nullable Object v) {
    return v == null ? null : v.toString();
  }

  static long integer(@Nullable Object v) {
    if (v instanceof Number n) {
      return n.longValue();
    }
    if (v == null) {
      return 0;
    }
    try {
      return Long.parseLong(Js.trim(v.toString()));
    } catch (NumberFormatException e) {
      return 0;
    }
  }

  static boolean bool(@Nullable Object v) {
    if (v instanceof Boolean b) {
      return b;
    }
    String s = v == null ? "" : asciiLower(v.toString());
    return s.equals("t") || s.equals("true") || s.equals("1");
  }

  /** A time as epoch milliseconds: milliseconds, an {@code Instant}, or ISO text; else null. */
  static @Nullable Long time(@Nullable Object v) {
    return switch (v) {
      case null -> null;
      case Number n -> n.longValue();
      case Timestamp t -> t.getTime();
      case Instant i -> i.toEpochMilli();
      case OffsetDateTime o -> o.toInstant().toEpochMilli();
      default -> {
        try {
          yield OffsetDateTime.parse(v.toString().trim().replace(' ', 'T'))
              .toInstant()
              .toEpochMilli();
        } catch (java.time.format.DateTimeParseException e) {
          yield null;
        }
      }
    };
  }

  static PgCronJob jobOf(Map<String, @Nullable Object> r) {
    return new PgCronJob(
        integer(r.get("jobid")),
        text(r.get("jobname")),
        Objects.requireNonNullElse(text(r.get("schedule")), ""),
        Objects.requireNonNullElse(text(r.get("database")), ""),
        Objects.requireNonNullElse(text(r.get("username")), ""),
        bool(r.get("active")));
  }

  static PgCronRow rowOf(Map<String, @Nullable Object> r) {
    return new PgCronRow(
        integer(r.get("runid")),
        integer(r.get("jobid")),
        text(r.get("status")),
        text(r.get("return_message")),
        time(r.get("start_time")),
        time(r.get("end_time")));
  }
}
