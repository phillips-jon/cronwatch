package dev.cronwatch.internal.evaluate;

import dev.cronwatch.Alert;
import dev.cronwatch.Condition;
import dev.cronwatch.JobState;
import dev.cronwatch.json.JsObject;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import org.jspecify.annotations.Nullable;

/**
 * A job's state being worked out: the fields of a {@link JobState}, open to change, as the SDK's
 * functions change a cloned state object. Used by one thread at a time.
 */
public final class MutableState {
  public String job;
  public final LinkedHashMap<Condition, Long> open;
  public long consecutiveFailures;
  public @Nullable Long silencedUntil;
  public @Nullable Long lastAlertAt;
  public @Nullable List<Condition> pendingRecovery;
  public @Nullable List<Alert> undelivered;
  public @Nullable Long version;
  public final JsObject extra;

  private MutableState(JobState s) {
    job = s.job();
    open = new LinkedHashMap<>(s.open());
    consecutiveFailures = s.consecutiveFailures();
    silencedUntil = s.silencedUntil();
    lastAlertAt = s.lastAlertAt();
    pendingRecovery = s.pendingRecovery() == null ? null : new ArrayList<>(s.pendingRecovery());
    undelivered = s.undelivered() == null ? null : new ArrayList<>(s.undelivered());
    version = s.version();
    extra = s.extra();
  }

  /** A changeable copy of the state. */
  public static MutableState of(JobState s) {
    return new MutableState(s);
  }

  /** The pending recoveries, made present. */
  public List<Condition> pending() {
    List<Condition> list = pendingRecovery;
    if (list == null) {
      list = new ArrayList<>();
      pendingRecovery = list;
    }
    return list;
  }

  /** The queued alerts, made present. */
  public List<Alert> queued() {
    List<Alert> list = undelivered;
    if (list == null) {
      list = new ArrayList<>();
      undelivered = list;
    }
    return list;
  }

  /** The state as it now stands. */
  public JobState toState() {
    return new JobState(
        job,
        open,
        consecutiveFailures,
        silencedUntil,
        lastAlertAt,
        pendingRecovery,
        undelivered,
        version,
        extra);
  }
}
