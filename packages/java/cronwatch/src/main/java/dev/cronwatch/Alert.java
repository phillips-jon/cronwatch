package dev.cronwatch;

import dev.cronwatch.Run.Values;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * A condition opening or closing, with the text every channel shows.
 *
 * <p>Build one with {@link #of}, not the canonical constructor: a record that may grow gains a
 * component in a minor release, which changes its constructor, while {@code of} keeps its
 * parameters and gives the new component its default.
 *
 * @param type what the alert says
 * @param run the run behind the alert, when there is one
 * @param details what the alert carries beyond its text
 * @param job the job's name
 * @param definition the job's definition when the alert was made
 * @param title one line, suitable as a notification title
 * @param message a few lines of plain text with the specifics
 * @param triage a short diagnosis from triage, when one was made
 * @param triageTried whether triage was tried for this alert; with {@code triage} null, it gave
 *     nothing and is not tried again
 * @param at when the alert was made, epoch milliseconds
 */
public record Alert(
    AlertType type,
    @Nullable Run run,
    AlertDetails details,
    String job,
    Definition definition,
    String title,
    String message,
    @Nullable String triage,
    boolean triageTried,
    long at) {

  /** Checks that the required components are there. */
  public Alert {
    Objects.requireNonNull(type, "type");
    Objects.requireNonNull(details, "details");
    Objects.requireNonNull(job, "job");
    Objects.requireNonNull(definition, "definition");
    Objects.requireNonNull(title, "title");
    Objects.requireNonNull(message, "message");
  }

  /** An alert with these fields, as a channel's test might build one. */
  public static Alert of(
      AlertType type,
      @Nullable Run run,
      AlertDetails details,
      String job,
      Definition definition,
      String title,
      String message,
      @Nullable String triage,
      boolean triageTried,
      long at) {
    return new Alert(type, run, details, job, definition, title, message, triage, triageTried, at);
  }

  /** This alert with triage tried and its diagnosis, or null when it gave nothing. */
  public Alert withTriage(@Nullable String diagnosis) {
    return new Alert(type, run, details, job, definition, title, message, diagnosis, true, at);
  }

  /** The alert as the SDK writes it. */
  public JsObject toValue() {
    JsObject o =
        new JsObject()
            .set("type", type.value())
            .set("run", run == null ? null : run.toValue())
            .set("details", details.toValue())
            .set("job", job)
            .set("definition", definition.toObject())
            .set("title", title)
            .set("message", message)
            .set("at", at);
    if (triageTried || triage != null) {
      o.set("triage", triage);
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
   * @throws Json.JsonException when it is not an alert
   */
  public static Alert fromJson(String text) {
    return fromValue(Json.parse(text));
  }

  /**
   * Reads the SDK's JSON value. A queued alert's run keeps the metrics that are numbers, as a
   * stored run row does, so one another writer stored otherwise cannot fail every read of the job's
   * state.
   *
   * @throws Json.JsonException when it is not an object
   */
  public static Alert fromValue(@Nullable Object v) {
    if (!(v instanceof JsObject o)) {
      throw new Json.JsonException("an alert must be an object, not " + Js.typeOf(v));
    }
    AlertType type = AlertType.of(Values.string(o, "type"));
    Run run = null;
    Object r = o.get("run");
    if (r instanceof JsObject ro) {
      JsObject copy = ro.copy();
      copy.set("metrics", Metrics.lenient(copy.get("metrics")).toValue());
      run = Run.fromValue(copy);
    } else if (r != null) {
      run = Run.fromValue(r);
    }
    JsObject details = o.get("details") instanceof JsObject d ? d : new JsObject();
    JsObject definition = o.get("definition") instanceof JsObject d ? d : new JsObject();
    return new Alert(
        type,
        run,
        AlertDetails.fromValue(type, details),
        Values.string(o, "job"),
        Definition.of(definition),
        Values.string(o, "title"),
        Values.string(o, "message"),
        Values.nullableString(o, "triage"),
        o.has("triage"),
        Values.integer(o, "at"));
  }
}
