package dev.cronwatch;

import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import org.jspecify.annotations.Nullable;

/**
 * An alert in {@link JobState#sending()}, the outbox: written with the state that opened its
 * condition, while the process that wrote it sends it. It leaves once that process records how the
 * send went; one still there after {@code until} (the process stopped part way) goes to {@code
 * undelivered} at the next check.
 *
 * @param until when the sender's lease runs out, epoch milliseconds; null for an entry another
 *     writer stored without a number there, which counts as run out
 * @param alert the alert, never with triage (triage is made when it is sent); null for an entry
 *     another writer stored without one, which is let go when its lease is seen to have run out
 */
public record SendingAlert(@Nullable Long until, @Nullable Alert alert) {

  /**
   * The entry as the SDK writes it. One read from JSON keeps what this release does not read (a key
   * a newer writer added, a {@code until} or {@code alert} it could not read), as the SDK carries
   * an entry unchanged.
   */
  public JsObject toValue() {
    JsObject o = new JsObject();
    if (until != null) {
      o.set("until", until);
    }
    if (alert != null) {
      o.set("alert", alert.toValue());
    }
    return Kept.withUnknown(o, Kept.get(this));
  }

  /**
   * Reads an entry leniently, as the SDK's {@code releaseSending} treats one: a {@code until} that
   * is not a number and an {@code alert} that is not an alert read as none, so an entry another
   * writer got wrong cannot make the whole state unreadable. Null for a value that is not an
   * object, which holds nothing to send.
   */
  static @Nullable SendingAlert fromValue(@Nullable Object v) {
    if (!(v instanceof JsObject o)) {
      return null;
    }
    Long until = o.get("until") instanceof Number n ? Js.toLong(n.doubleValue()) : null;
    Alert alert = null;
    if (o.get("alert") instanceof JsObject a) {
      try {
        alert = Alert.fromValue(a);
      } catch (Json.JsonException e) {
        // Not an alert: it could never be sent.
      }
    }
    SendingAlert entry = new SendingAlert(until, alert);
    Kept.put(entry, o);
    return entry;
  }
}
