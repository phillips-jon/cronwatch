package dev.cronwatch;

import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/**
 * A run's numbers, in JavaScript's key order: names that are array indices ({@code "10"}, {@code
 * "200"}) first in ascending order, then the rest in the order they were first reported. Budgets
 * use the same order. Immutable; {@link #with} gives a copy with one more value.
 */
public final class Metrics {
  private static final Metrics EMPTY = new Metrics(new JsObject());

  private final JsObject values;

  private Metrics(JsObject values) {
    this.values = values;
  }

  /** No metrics. */
  public static Metrics empty() {
    return EMPTY;
  }

  /**
   * The metrics of a map, in its iteration order (a {@link LinkedHashMap} or {@link Map#of} pairs
   * given in order keep it; a {@code HashMap} gives its own), array-index names first.
   *
   * @throws IllegalArgumentException for a value that is not a finite number
   */
  public static Metrics of(Map<String, ? extends Number> values) {
    JsObject o = new JsObject();
    for (Map.Entry<String, ? extends Number> e : values.entrySet()) {
      double v = e.getValue().doubleValue();
      if (!Double.isFinite(v)) {
        throw new IllegalArgumentException("metric \"" + e.getKey() + "\" must be a finite number");
      }
      o.set(e.getKey(), v);
    }
    return new Metrics(o);
  }

  /**
   * A copy with {@code name} set: a later value replaces an earlier one in its place, and a new
   * name takes its place in JavaScript's order.
   */
  public Metrics with(String name, double value) {
    JsObject o = values.copy();
    o.set(name, value);
    return new Metrics(o);
  }

  /** {@code {...this, ...over}}: {@code over}'s values win, each name keeping its first place. */
  public Metrics merged(Metrics over) {
    if (over.isEmpty()) {
      return this;
    }
    JsObject o = values.copy();
    for (Map.Entry<String, @Nullable Object> e : over.values.entries()) {
      o.set(e.getKey(), e.getValue());
    }
    return new Metrics(o);
  }

  /** The value reported for {@code name}, or null. */
  public @Nullable Double get(String name) {
    return values.get(name) instanceof Double d ? d : null;
  }

  /** The names and values in order, unmodifiable. */
  public Map<String, Double> asMap() {
    Map<String, Double> out = new LinkedHashMap<>();
    for (Map.Entry<String, @Nullable Object> e : values.entries()) {
      out.put(e.getKey(), (Double) e.getValue());
    }
    return Collections.unmodifiableMap(out);
  }

  /** How many there are. */
  public int size() {
    return values.size();
  }

  /** Whether there are none. */
  public boolean isEmpty() {
    return values.isEmpty();
  }

  /** The metrics as a JSON object (a copy). */
  public JsObject toValue() {
    return values.copy();
  }

  /** The SDK's JSON. */
  public String toJson() {
    return values.toJson();
  }

  /**
   * Reads a JSON object of numbers; {@code null} is none.
   *
   * @throws Json.JsonException for anything else, or a value that is not a number
   */
  public static Metrics fromValue(@Nullable Object v) {
    if (v == null) {
      return EMPTY;
    }
    if (!(v instanceof JsObject o)) {
      throw new Json.JsonException("metrics must be an object, not " + Js.typeOf(v));
    }
    JsObject out = new JsObject();
    for (Map.Entry<String, @Nullable Object> e : o.entries()) {
      if (!(e.getValue() instanceof Number n)) {
        throw new Json.JsonException(
            "metric "
                + Json.stringify(e.getKey())
                + " must be a number, not "
                + Js.typeOf(e.getValue()));
      }
      out.set(e.getKey(), n.doubleValue());
    }
    return new Metrics(out);
  }

  /**
   * A stored row's metrics as the SDK reads them: the numbers of an object, whatever else it holds,
   * and none for anything else.
   */
  public static Metrics lenient(@Nullable Object v) {
    JsObject out = new JsObject();
    if (v instanceof JsObject o) {
      for (Map.Entry<String, @Nullable Object> e : o.entries()) {
        if (e.getValue() instanceof Number n) {
          out.set(e.getKey(), n.doubleValue());
        }
      }
    }
    return new Metrics(out);
  }

  /** The metrics' JSON. */
  @Override
  public String toString() {
    return toJson();
  }

  /** Equal when both hold the same names in the same order with the same values. */
  @Override
  public boolean equals(@Nullable Object o) {
    return o instanceof Metrics m && m.values.equals(values);
  }

  @Override
  public int hashCode() {
    return values.hashCode();
  }
}
