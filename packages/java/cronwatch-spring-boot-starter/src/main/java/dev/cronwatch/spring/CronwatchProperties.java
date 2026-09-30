package dev.cronwatch.spring;

import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.jspecify.annotations.Nullable;
import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * The client's and the scheduler integrations' settings, {@code cronwatch.*}. Each is optional; the
 * defaults are the SDK's.
 *
 * <pre>
 * # auto, memory or jdbc (the app's DataSource)
 * cronwatch.store=auto
 * cronwatch.retention=30d
 * cronwatch.check-every=1m
 * cronwatch.jobs[NightlyReports.build].grace=15m
 * </pre>
 */
@ConfigurationProperties(prefix = "cronwatch")
public class CronwatchProperties {
  /** Where the client keeps jobs, runs and state. */
  public enum StoreKind {
    /**
     * {@code SqlStore} over the app's one {@code DataSource} when it has one, else the memory
     * store.
     */
    AUTO,
    /** The in-memory store, which forgets on restart. */
    MEMORY,
    /** {@code SqlStore} over the app's one {@code DataSource}. */
    JDBC
  }

  /** How the check runs across the instances of the app. */
  public enum CheckMode {
    /**
     * Through ShedLock when the app has a {@code LockProvider}, else through Quartz when its
     * scheduler is clustered, else in each instance.
     */
    AUTO,
    /** In each instance, on the interval. */
    LOCAL,
    /** Once per interval across the cluster, under a ShedLock lock of its own name. */
    SHEDLOCK,
    /** Once per interval across the cluster, as a Quartz job ({@code CronwatchCheckJob}). */
    QUARTZ,
    /** Never: the app runs its checks elsewhere. */
    NONE
  }

  /** Made by Spring's binder. */
  public CronwatchProperties() {}

  /** Whether the starter makes a client at all. */
  private boolean enabled = true;

  /**
   * The app's name for its tag under each integration's and for its runs' ids. Default {@code
   * $CRONWATCH_APP_ID}, else {@code spring.application.name}, else the main class.
   */
  private @Nullable String app;

  /** Where jobs, runs and state live. */
  private StoreKind store = StoreKind.AUTO;

  /** The prefix of the store's table names. */
  private @Nullable String tablePrefix;

  /** How long finished runs are kept, as the SDK's text. */
  private @Nullable String retention;

  /** The secret job handlers' requests must carry. Default {@code $CRON_SECRET}. */
  private @Nullable String cronSecret;

  /** Where alerts are sent from: {@code now} or {@code at-check}. */
  private String deliver = "now";

  /** Whether run output and errors are redacted before they are stored. */
  private boolean redact = true;

  /** Whether runs still open when the JVM stops are marked failed. */
  private boolean shutdownHook = true;

  /** How often the check runs. */
  private Duration checkEvery = Duration.ofMinutes(1);

  /** How the check runs across the instances of the app. */
  private CheckMode checkMode = CheckMode.AUTO;

  private final Defaults defaults = new Defaults();
  private final Scheduled scheduled = new Scheduled();
  private final Quartz quartz = new Quartz();
  private final Map<String, JobProperties> jobs = new LinkedHashMap<>();

  /** Options for every job that does not set its own. */
  public static class Defaults {
    /** Made by Spring's binder. */
    public Defaults() {}

    private @Nullable String grace;
    private @Nullable String timeout;
    private @Nullable String timezone;
    private @Nullable Integer failuresBeforeAlert;

    /** How late a run may start before it counts as missed. */
    public @Nullable String getGrace() {
      return grace;
    }

    /** Sets {@link #getGrace()}. */
    public void setGrace(@Nullable String grace) {
      this.grace = grace;
    }

    /** How long a run may go on before it is treated as stuck. */
    public @Nullable String getTimeout() {
      return timeout;
    }

    /** Sets {@link #getTimeout()}. */
    public void setTimeout(@Nullable String timeout) {
      this.timeout = timeout;
    }

    /** The zone cron schedules are read in. */
    public @Nullable String getTimezone() {
      return timezone;
    }

    /** Sets {@link #getTimezone()}. */
    public void setTimezone(@Nullable String timezone) {
      this.timezone = timezone;
    }

    /** Alerts on the nth consecutive failure rather than the first. */
    public @Nullable Integer getFailuresBeforeAlert() {
      return failuresBeforeAlert;
    }

    /** Sets {@link #getFailuresBeforeAlert()}. */
    public void setFailuresBeforeAlert(@Nullable Integer failuresBeforeAlert) {
      this.failuresBeforeAlert = failuresBeforeAlert;
    }
  }

  /** The {@code @Scheduled} integration. */
  public static class Scheduled {
    /** Made by Spring's binder. */
    public Scheduled() {}

    private boolean enabled = true;

    /** Whether {@code @Scheduled} methods are watched. */
    public boolean isEnabled() {
      return enabled;
    }

    /** Sets {@link #isEnabled()}. */
    public void setEnabled(boolean enabled) {
      this.enabled = enabled;
    }
  }

  /** The Quartz integration. */
  public static class Quartz {
    /** Made by Spring's binder. */
    public Quartz() {}

    private boolean enabled = true;

    /**
     * Whether the app's Quartz schedulers are watched, which needs {@code cronwatch-quartz} on the
     * class path: the starter's dependency on it is optional.
     */
    public boolean isEnabled() {
      return enabled;
    }

    /** Sets {@link #isEnabled()}. */
    public void setEnabled(boolean enabled) {
      this.enabled = enabled;
    }
  }

  /**
   * One job's options, under its name ({@code cronwatch.jobs[NightlyReports.build].grace=15m}): the
   * same as {@code @CronwatchJob}'s, and given after them.
   */
  public static class JobProperties {
    /** Made by Spring's binder. */
    public JobProperties() {}

    private @Nullable String name;
    private @Nullable String description;
    private @Nullable String grace;
    private @Nullable String timeout;
    private @Nullable String maxDuration;
    private @Nullable String expect;
    private List<String> tags = new ArrayList<>();
    private @Nullable Integer failuresBeforeAlert;

    /** The name to watch the job under in place of its own. */
    public @Nullable String getName() {
      return name;
    }

    /** Sets {@link #getName()}. */
    public void setName(@Nullable String name) {
      this.name = name;
    }

    /** Describes the job on the dashboard. */
    public @Nullable String getDescription() {
      return description;
    }

    /** Sets {@link #getDescription()}. */
    public void setDescription(@Nullable String description) {
      this.description = description;
    }

    /** How late a run may start before it counts as missed. */
    public @Nullable String getGrace() {
      return grace;
    }

    /** Sets {@link #getGrace()}. */
    public void setGrace(@Nullable String grace) {
      this.grace = grace;
    }

    /** How long a run may go on before it is treated as stuck. */
    public @Nullable String getTimeout() {
      return timeout;
    }

    /** Sets {@link #getTimeout()}. */
    public void setTimeout(@Nullable String timeout) {
      this.timeout = timeout;
    }

    /** Alerts when a successful run takes longer. */
    public @Nullable String getMaxDuration() {
      return maxDuration;
    }

    /** Sets {@link #getMaxDuration()}. */
    public void setMaxDuration(@Nullable String maxDuration) {
      this.maxDuration = maxDuration;
    }

    /** Text a successful run's output must contain. */
    public @Nullable String getExpect() {
      return expect;
    }

    /** Sets {@link #getExpect()}. */
    public void setExpect(@Nullable String expect) {
      this.expect = expect;
    }

    /** Labels for the job. */
    public List<String> getTags() {
      return tags;
    }

    /** Sets {@link #getTags()}. */
    public void setTags(List<String> tags) {
      this.tags = tags;
    }

    /** Alerts on the nth consecutive failure rather than the first. */
    public @Nullable Integer getFailuresBeforeAlert() {
      return failuresBeforeAlert;
    }

    /** Sets {@link #getFailuresBeforeAlert()}. */
    public void setFailuresBeforeAlert(@Nullable Integer failuresBeforeAlert) {
      this.failuresBeforeAlert = failuresBeforeAlert;
    }
  }

  /** Whether the starter makes a client at all. */
  public boolean isEnabled() {
    return enabled;
  }

  /** Sets {@link #isEnabled()}. */
  public void setEnabled(boolean enabled) {
    this.enabled = enabled;
  }

  /** The app's name for its tags and runs' ids. */
  public @Nullable String getApp() {
    return app;
  }

  /** Sets {@link #getApp()}. */
  public void setApp(@Nullable String app) {
    this.app = app;
  }

  /** Where jobs, runs and state live. */
  public StoreKind getStore() {
    return store;
  }

  /** Sets {@link #getStore()}. */
  public void setStore(StoreKind store) {
    this.store = store;
  }

  /** The prefix of the store's table names. */
  public @Nullable String getTablePrefix() {
    return tablePrefix;
  }

  /** Sets {@link #getTablePrefix()}. */
  public void setTablePrefix(@Nullable String tablePrefix) {
    this.tablePrefix = tablePrefix;
  }

  /** How long finished runs are kept. */
  public @Nullable String getRetention() {
    return retention;
  }

  /** Sets {@link #getRetention()}. */
  public void setRetention(@Nullable String retention) {
    this.retention = retention;
  }

  /** The secret job handlers' requests must carry. */
  public @Nullable String getCronSecret() {
    return cronSecret;
  }

  /** Sets {@link #getCronSecret()}. */
  public void setCronSecret(@Nullable String cronSecret) {
    this.cronSecret = cronSecret;
  }

  /** Where alerts are sent from. */
  public String getDeliver() {
    return deliver;
  }

  /** Sets {@link #getDeliver()}. */
  public void setDeliver(String deliver) {
    this.deliver = deliver;
  }

  /** Whether run output and errors are redacted. */
  public boolean isRedact() {
    return redact;
  }

  /** Sets {@link #isRedact()}. */
  public void setRedact(boolean redact) {
    this.redact = redact;
  }

  /** Whether the client's shutdown hook is registered. */
  public boolean isShutdownHook() {
    return shutdownHook;
  }

  /** Sets {@link #isShutdownHook()}. */
  public void setShutdownHook(boolean shutdownHook) {
    this.shutdownHook = shutdownHook;
  }

  /** How often the check runs. */
  public Duration getCheckEvery() {
    return checkEvery;
  }

  /** Sets {@link #getCheckEvery()}. */
  public void setCheckEvery(Duration checkEvery) {
    this.checkEvery = checkEvery;
  }

  /** How the check runs across the instances of the app. */
  public CheckMode getCheckMode() {
    return checkMode;
  }

  /** Sets {@link #getCheckMode()}. */
  public void setCheckMode(CheckMode checkMode) {
    this.checkMode = checkMode;
  }

  /** Options for every job. */
  public Defaults getDefaults() {
    return defaults;
  }

  /** The {@code @Scheduled} integration. */
  public Scheduled getScheduled() {
    return scheduled;
  }

  /** The Quartz integration. */
  public Quartz getQuartz() {
    return quartz;
  }

  /** Options for jobs by name. */
  public Map<String, JobProperties> getJobs() {
    return jobs;
  }

  /** Names what is set, never the secret. */
  @Override
  public String toString() {
    return "CronwatchProperties[store="
        + store
        + ", cronSecret="
        + (cronSecret == null ? "unset" : "set")
        + ", checkMode="
        + checkMode
        + "]";
  }
}
