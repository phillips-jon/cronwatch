package dev.cronwatch;

import dev.cronwatch.Run.Values;
import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import org.jspecify.annotations.Nullable;

/**
 * What the checks remember about a job between runs.
 *
 * @param job the job's name
 * @param open the conditions open, each with when it opened, in the order they opened
 * @param consecutiveFailures failed runs in a row
 * @param silencedUntil when a silence ends, or null
 * @param lastAlertAt when an alert last reached at least one channel, or null
 * @param pendingRecovery conditions that alerted and have since closed, waiting for the recovered
 *     alert the next successful run sends; null for a state written before the field existed
 * @param undelivered alerts no channel accepted, each retried once per check; null when absent
 * @param version goes up by one on every write (see {@code Store.compareAndSetState}); null for a
 *     state written before versions, or one whose stored version is not a whole number, which
 *     counts as 0 ({@link #countedVersion})
 * @param extra the keys after the SDK's seven, in stored order: {@code version} where it was stored
 *     (the {@code version} component is what is written there) and any a newer writer added, so a
 *     state is written back as the SDK's spread would write it
 */
public record JobState(
    String job,
    Map<Condition, Long> open,
    long consecutiveFailures,
    @Nullable Long silencedUntil,
    @Nullable Long lastAlertAt,
    @Nullable List<Condition> pendingRecovery,
    @Nullable List<Alert> undelivered,
    @Nullable Long version,
    JsObject extra) {

  private static final Set<String> KEYS =
      Set.of(
          "job",
          "open",
          "consecutiveFailures",
          "silencedUntil",
          "lastAlertAt",
          "pendingRecovery",
          "undelivered");

  /** Keeps unmodifiable copies. */
  public JobState {
    Objects.requireNonNull(job, "job");
    open = Collections.unmodifiableMap(new LinkedHashMap<>(open));
    pendingRecovery = pendingRecovery == null ? null : List.copyOf(pendingRecovery);
    undelivered = undelivered == null ? null : List.copyOf(undelivered);
    extra = extra.copy();
  }

  /** A new state for a job: nothing open, no failures, empty lists. */
  public static JobState empty(String job) {
    return new JobState(job, Map.of(), 0, null, null, List.of(), List.of(), null, new JsObject());
  }

  /** The keys after the SDK's seven, as a copy. */
  @Override
  public JsObject extra() {
    return extra.copy();
  }

  /** When {@code condition} opened, or null when it is not open. */
  public @Nullable Long openAt(Condition condition) {
    return open.get(condition);
  }

  /**
   * The version this state counts as for {@code compareAndSetState}: {@link #version} when it is
   * from 0 to 2^53 - 1, else 0.
   */
  public long countedVersion() {
    Long v = version;
    return v != null && v >= 0 && v <= Js.MAX_SAFE_INTEGER ? v : 0;
  }

  /** This state with another version. */
  public JobState withVersion(@Nullable Long version) {
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

  /** The state as the SDK writes it. */
  public JsObject toValue() {
    JsObject openObject = new JsObject();
    for (Map.Entry<Condition, Long> e : open.entrySet()) {
      openObject.set(e.getKey().value(), e.getValue());
    }
    JsObject o =
        new JsObject()
            .set("job", job)
            .set("open", openObject)
            .set("consecutiveFailures", consecutiveFailures)
            .set("silencedUntil", silencedUntil)
            .set("lastAlertAt", lastAlertAt);
    if (pendingRecovery != null) {
      List<Object> list = new ArrayList<>();
      for (Condition c : pendingRecovery) {
        list.add(c.value());
      }
      o.set("pendingRecovery", list);
    }
    if (undelivered != null) {
      List<Object> list = new ArrayList<>();
      for (Alert a : undelivered) {
        list.add(a.toValue());
      }
      o.set("undelivered", list);
    }
    boolean wroteVersion = false;
    for (Map.Entry<String, @Nullable Object> e : extra.entries()) {
      if (e.getKey().equals("version")) {
        if (version != null) {
          o.set("version", version);
          wroteVersion = true;
        }
        continue;
      }
      o.set(e.getKey(), Json.copy(e.getValue()));
    }
    if (version != null && !wroteVersion) {
      o.set("version", version);
    }
    return o;
  }

  /** The SDK's JSON. */
  public String toJson() {
    return toValue().toJson();
  }

  /**
   * Reads the SDK's JSON.
   *
   * @throws Json.JsonException when it is not a state
   */
  public static JobState fromJson(String text) {
    return fromValue(Json.parse(text));
  }

  /**
   * Reads the SDK's JSON value. A queued entry that is not an alert is dropped rather than fail
   * every read of the state, since it could never be delivered.
   *
   * @throws Json.JsonException when it is not an object
   */
  public static JobState fromValue(@Nullable Object v) {
    if (!(v instanceof JsObject o)) {
      throw new Json.JsonException("a job state must be an object, not " + Json.kind(v));
    }
    Map<Condition, Long> open = new LinkedHashMap<>();
    if (o.get("open") instanceof JsObject opened) {
      for (Map.Entry<String, @Nullable Object> e : opened.entries()) {
        open.put(
            Condition.of(e.getKey()),
            e.getValue() instanceof Number n ? Js.toLong(n.doubleValue()) : 0L);
      }
    }
    List<Condition> pending = null;
    if (o.get("pendingRecovery") instanceof List<?> list) {
      pending = new ArrayList<>();
      for (Object c : list) {
        if (c instanceof String s) {
          pending.add(Condition.of(s));
        }
      }
    }
    List<Alert> undelivered = null;
    if (o.get("undelivered") instanceof List<?> list) {
      undelivered = new ArrayList<>();
      for (Object a : list) {
        try {
          undelivered.add(Alert.fromValue(a));
        } catch (Json.JsonException e) {
          // Not an alert: it could never be delivered.
        }
      }
    }
    Long version = null;
    JsObject extra = new JsObject();
    for (Map.Entry<String, @Nullable Object> e : o.entries()) {
      if (KEYS.contains(e.getKey())) {
        continue;
      }
      if (e.getKey().equals("version")) {
        // A version that is not a whole number (1.5, "x") reads as none; one out of range is
        // kept, so the state writes back as it was read. Either counts as 0.
        version =
            e.getValue() instanceof Number n && Js.isInteger(n.doubleValue())
                ? Js.toLong(n.doubleValue())
                : null;
      }
      extra.set(e.getKey(), e.getValue());
    }
    return new JobState(
        Values.string(o, "job"),
        open,
        Evaluate.failureCount(o.get("consecutiveFailures")),
        Values.nullableInteger(o, "silencedUntil"),
        Values.nullableInteger(o, "lastAlertAt"),
        pending,
        undelivered,
        version,
        extra);
  }
}
