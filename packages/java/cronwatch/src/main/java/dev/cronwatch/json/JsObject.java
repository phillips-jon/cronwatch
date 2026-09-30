package dev.cronwatch.json;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.TreeMap;
import org.jspecify.annotations.Nullable;

/**
 * A JavaScript object: its keys in JavaScript's order, which is every key that is an array index (a
 * canonical whole number below 2^32 - 1) in ascending order, then every other key in the order it
 * was first set. Setting a key already there keeps its place and takes the new value, as a
 * JavaScript object does.
 *
 * <p>Values are what {@link Json} reads and writes: {@code null}, a {@link Boolean}, a {@link
 * Number}, a {@link String}, a {@link List} of values or a {@code JsObject}. A definition, a
 * state's unknown keys and a stored alert are kept as these, so a field another writer added is
 * written back where it was.
 *
 * <p>Not safe for use from several threads at once without a lock of the caller's.
 */
public final class JsObject {
  private final TreeMap<Long, Entry> indexed = new TreeMap<>();
  private final LinkedHashMap<String, @Nullable Object> named = new LinkedHashMap<>();

  private record Entry(String key, @Nullable Object value) {}

  /** An empty object. */
  public JsObject() {}

  /**
   * Whether a key is an array index, which JavaScript orders before every other key: the number, or
   * -1 when it is not one.
   */
  static long arrayIndex(String key) {
    int n = key.length();
    if (n == 0 || n > 10 || (n > 1 && key.charAt(0) == '0')) {
      return -1;
    }
    long v = 0;
    for (int i = 0; i < n; i++) {
      char c = key.charAt(i);
      if (c < '0' || c > '9') {
        return -1;
      }
      v = v * 10 + (c - '0');
    }
    return v >= (1L << 32) - 1 ? -1 : v;
  }

  /**
   * Gives {@code key} the value: a new key takes its place in JavaScript's order, a key already
   * there keeps its place.
   *
   * @return this object, for building one in a line
   */
  public JsObject set(String key, @Nullable Object value) {
    Objects.requireNonNull(key, "key");
    long n = arrayIndex(key);
    if (n >= 0) {
      indexed.put(n, new Entry(key, value));
    } else {
      named.put(key, value);
    }
    return this;
  }

  /** The value at {@code key}, or null when it is absent (see {@link #has}) or null. */
  public @Nullable Object get(String key) {
    long n = arrayIndex(key);
    if (n >= 0) {
      Entry e = indexed.get(n);
      return e == null ? null : e.value();
    }
    return named.get(key);
  }

  /** Whether the key is there, whatever its value. */
  public boolean has(String key) {
    long n = arrayIndex(key);
    return n >= 0 ? indexed.containsKey(n) : named.containsKey(key);
  }

  /** Removes {@code key}, giving back its value. */
  public @Nullable Object remove(String key) {
    long n = arrayIndex(key);
    if (n >= 0) {
      Entry e = indexed.remove(n);
      return e == null ? null : e.value();
    }
    return named.remove(key);
  }

  /** {@code Object.keys}: the keys in JavaScript's order. */
  public List<String> keys() {
    List<String> out = new ArrayList<>(size());
    for (Entry e : indexed.values()) {
      out.add(e.key());
    }
    out.addAll(named.keySet());
    return Collections.unmodifiableList(out);
  }

  /** The keys and values in order, as an unmodifiable copy. */
  public List<Map.Entry<String, @Nullable Object>> entries() {
    List<Map.Entry<String, @Nullable Object>> out = new ArrayList<>(size());
    for (Entry e : indexed.values()) {
      out.add(new java.util.AbstractMap.SimpleImmutableEntry<>(e.key(), e.value()));
    }
    for (Map.Entry<String, @Nullable Object> e : named.entrySet()) {
      out.add(new java.util.AbstractMap.SimpleImmutableEntry<>(e.getKey(), e.getValue()));
    }
    return Collections.unmodifiableList(out);
  }

  /** How many keys there are. */
  public int size() {
    return indexed.size() + named.size();
  }

  /** Whether there are none. */
  public boolean isEmpty() {
    return size() == 0;
  }

  /** A deep copy: nested objects and lists are copied too. */
  public JsObject copy() {
    JsObject out = new JsObject();
    for (Map.Entry<String, @Nullable Object> e : entries()) {
      out.set(e.getKey(), copyValue(e.getValue()));
    }
    return out;
  }

  /** A deep copy of a JSON value. */
  static @Nullable Object copyValue(@Nullable Object v) {
    if (v instanceof JsObject o) {
      return o.copy();
    }
    if (v instanceof List<?> list) {
      List<@Nullable Object> out = new ArrayList<>(list.size());
      for (Object x : list) {
        out.add(copyValue(x));
      }
      return out;
    }
    return v;
  }

  /** {@code JSON.stringify} of the object. */
  public String toJson() {
    return Json.stringify(this);
  }

  /** The object's JSON. */
  @Override
  public String toString() {
    return toJson();
  }

  /** Equal when both hold the same keys in the same order with values whose JSON is the same. */
  @Override
  public boolean equals(@Nullable Object other) {
    return other instanceof JsObject o && toJson().equals(o.toJson());
  }

  @Override
  public int hashCode() {
    return toJson().hashCode();
  }
}
