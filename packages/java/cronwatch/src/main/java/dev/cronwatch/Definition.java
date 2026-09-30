package dev.cronwatch;

import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import org.jspecify.annotations.Nullable;

/**
 * A job's definition as a store holds it: the SDK's JSON object, its fields in the order they were
 * given (the client's defaults, then the job's options, then {@code name}), {@code expect}
 * described in words and last. Fields a newer writer added are kept. Immutable.
 */
public final class Definition {
  private final JsObject fields;

  private Definition(JsObject fields) {
    this.fields = fields;
  }

  /** A definition holding a copy of these fields. */
  public static Definition of(JsObject fields) {
    return new Definition(fields.copy());
  }

  /**
   * Reads a JSON object.
   *
   * @throws Json.JsonException when the text is not a JSON object
   */
  public static Definition fromJson(String text) {
    return new Definition(Json.parseObject(text));
  }

  /** The job's name, or {@code ""}. */
  public String name() {
    return string("name");
  }

  /** The cron expression or {@code every <duration>}, or null. */
  public @Nullable String schedule() {
    return fields.get("schedule") instanceof String s ? s : null;
  }

  /** The IANA zone the schedule is read in, or null. */
  public @Nullable String timezone() {
    return fields.get("timezone") instanceof String s ? s : null;
  }

  /** The job's description, or null. */
  public @Nullable String description() {
    return fields.get("description") instanceof String s ? s : null;
  }

  /** Describes the expect rule ({@code contains "done"}), or null. */
  public @Nullable String expect() {
    return fields.get("expect") instanceof String s ? s : null;
  }

  /** The job's tags. */
  public List<String> tags() {
    List<String> out = new ArrayList<>();
    if (fields.get("tags") instanceof List<?> list) {
      for (Object t : list) {
        if (t instanceof String s) {
          out.add(s);
        }
      }
    }
    return Collections.unmodifiableList(out);
  }

  /** A field as JSON reads it: a copy of it, or null when absent (see {@link #has}). */
  public @Nullable Object get(String key) {
    return Json.copy(fields.get(key));
  }

  /** Whether the field is there. */
  public boolean has(String key) {
    return fields.has(key);
  }

  /** The fields present, in order. */
  public List<String> keys() {
    return fields.keys();
  }

  /** The definition as a JSON object (a copy). */
  public JsObject toObject() {
    return fields.copy();
  }

  /** The SDK's JSON. */
  public String toJson() {
    return fields.toJson();
  }

  private String string(String key) {
    return fields.get(key) instanceof String s ? s : "";
  }

  /** The definition's JSON. */
  @Override
  public String toString() {
    return toJson();
  }

  /** Equal when the JSON is the same, keys in the same order. */
  @Override
  public boolean equals(@Nullable Object o) {
    return o instanceof Definition d && d.fields.equals(fields);
  }

  @Override
  public int hashCode() {
    return fields.hashCode();
  }
}
