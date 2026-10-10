package dev.cronwatch.pgcron;

import dev.cronwatch.CronwatchException;
import dev.cronwatch.Definition;
import dev.cronwatch.JobOptions;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.function.Function;
import java.util.function.Predicate;
import org.jspecify.annotations.Nullable;

/**
 * How {@link PgCron#source(javax.sql.DataSource, PgCronOptions)} watches pg_cron: the SDK's {@code
 * PgCronOptions}, with its {@code jobs} as {@code jobs}, {@code jobIds}, and {@code pick}, as the
 * Go, Rust, and Elixir ports have them.
 *
 * <pre>{@code
 * PgCronOptions.builder()
 *     .prefix("db:")
 *     .jobs("nightly vacuum", "rollup")
 *     .options(JobOptions.builder().grace("5m").timeout("30m"))
 *     .build();
 * }</pre>
 */
public final class PgCronOptions {
  final @Nullable List<String> jobs;
  final @Nullable List<Long> jobIds;
  final @Nullable Predicate<PgCronJob> pick;
  final String prefix;
  final @Nullable Function<PgCronJob, String> jobName;
  final @Nullable Function<PgCronJob, JobOptions> options;
  final String timezone;

  private PgCronOptions(Builder b) {
    this.jobs = b.jobs == null ? null : List.copyOf(b.jobs);
    this.jobIds = b.jobIds == null ? null : List.copyOf(b.jobIds);
    this.pick = b.pick;
    this.prefix = b.prefix;
    this.jobName = b.jobName;
    this.options = b.options;
    this.timezone = b.timezone;
  }

  /** The defaults: every job the role can see, no prefix, the server's {@code cron.timezone}. */
  public static PgCronOptions defaults() {
    return builder().build();
  }

  /** Options to set. */
  public static Builder builder() {
    return new Builder();
  }

  /** Names what is set, never a value. */
  @Override
  public String toString() {
    List<String> set = new ArrayList<>();
    if (jobs != null) {
      set.add("jobs");
    }
    if (jobIds != null) {
      set.add("jobIds");
    }
    if (pick != null) {
      set.add("pick");
    }
    if (!prefix.isEmpty()) {
      set.add("prefix");
    }
    if (jobName != null) {
      set.add("jobName");
    }
    if (options != null) {
      set.add("options");
    }
    if (!timezone.isEmpty()) {
      set.add("timezone");
    }
    return "PgCronOptions" + set;
  }

  /** Sets the options. Not safe for use from several threads at once. */
  public static final class Builder {
    private @Nullable List<String> jobs;
    private @Nullable List<Long> jobIds;
    private @Nullable Predicate<PgCronJob> pick;
    private String prefix = "";
    private @Nullable Function<PgCronJob, String> jobName;
    private @Nullable Function<PgCronJob, JobOptions> options;

    /** The options for every job, when {@link #options(JobOptions)} gave them, checked at build. */
    private @Nullable JobOptions fixed;

    private String timezone = "";

    private Builder() {}

    /**
     * Watches the jobs of these names (with {@link #jobIds}, a job either names). Default every job
     * the role can see.
     */
    public Builder jobs(String... names) {
      return jobs(List.of(names));
    }

    /** {@link #jobs(String...)} from a list. */
    public Builder jobs(List<String> names) {
      this.jobs = List.copyOf(names);
      return this;
    }

    /**
     * Watches the jobs of these ids (with {@link #jobs}, a job either names). Default every job the
     * role can see.
     */
    public Builder jobIds(long... ids) {
      List<Long> list = new ArrayList<>();
      for (long id : ids) {
        list.add(id);
      }
      this.jobIds = list;
      return this;
    }

    /** Watches the jobs this answers true for, in place of {@link #jobs} and {@link #jobIds}. */
    public Builder pick(Predicate<PgCronJob> pick) {
      this.pick = Objects.requireNonNull(pick, "pick");
      return this;
    }

    /**
     * Goes before every job name, to keep them apart from the app's own ({@code "db:"}). It also
     * keeps run ids apart. Default none.
     */
    public Builder prefix(String prefix) {
      this.prefix = Objects.requireNonNull(prefix, "prefix");
      return this;
    }

    /**
     * The CronWatch name for a job. Default {@link PgCron#jobName}: its jobname with anything other
     * than letters, digits, {@code .}, {@code _}, {@code :}, and {@code -} turned into {@code -},
     * or {@code pg_cron:<jobid>} when it has none. The prefix goes in front either way. One that
     * throws or returns null, like a {@code pick} or {@code options} function that throws, is
     * reported once and fails only that job, which keeps its last declaration until the function
     * works again.
     */
    public Builder jobName(Function<PgCronJob, String> jobName) {
      this.jobName = Objects.requireNonNull(jobName, "jobName");
      return this;
    }

    /**
     * Grace, timeout, maxDuration, expect, and the rest, for every job. The schedule and timezone
     * always come from pg_cron, so options that set either are refused by {@link #build}.
     */
    public Builder options(JobOptions options) {
      JobOptions copy = options.copy();
      this.options = job -> copy;
      this.fixed = copy;
      return this;
    }

    /**
     * The options for each job, as a function of the job. Options that set a schedule or timezone
     * are reported and the job is not declared.
     */
    public Builder options(Function<PgCronJob, JobOptions> options) {
      this.options = Objects.requireNonNull(options, "options");
      this.fixed = null;
      return this;
    }

    /**
     * The zone pg_cron reads its cron expressions in. Default the server's {@code cron.timezone},
     * read from {@code pg_settings}, which shows it only to roles with {@code
     * pg_read_all_settings}; UTC (pg_cron's default) is assumed when it cannot be read.
     */
    public Builder timezone(String timezone) {
      this.timezone = Objects.requireNonNull(timezone, "timezone");
      return this;
    }

    /**
     * The options.
     *
     * @throws CronwatchException of kind {@code INVALID} for {@code pick} given with {@code jobs}
     *     or {@code jobIds}, or options that set a schedule or timezone
     */
    public PgCronOptions build() {
      if (pick != null && (jobs != null || jobIds != null)) {
        throw CronwatchException.invalid("PgCronOptions: give pick, or jobs and jobIds, not both");
      }
      if (fixed != null && fromPgCron(fixed.describe("x"))) {
        throw CronwatchException.invalid(
            "PgCronOptions: options may not set a schedule or timezone; they come from pg_cron");
      }
      return new PgCronOptions(this);
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "PgCronOptions.Builder";
    }
  }

  /** Whether options set what only pg_cron gives: a schedule or a timezone. */
  static boolean fromPgCron(Definition definition) {
    return definition.has("schedule") || definition.has("timezone");
  }
}
