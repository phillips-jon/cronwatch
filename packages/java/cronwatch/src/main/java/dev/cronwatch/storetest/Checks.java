package dev.cronwatch.storetest;

import dev.cronwatch.JobState;
import dev.cronwatch.Run;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/** What the contract and the replay share: store calls that fail as assertions, and comparisons. */
final class Checks {
  private Checks() {}

  /** A store call. */
  @FunctionalInterface
  interface Call<T> {
    T call() throws Exception;
  }

  /** A store call with no answer. */
  @FunctionalInterface
  interface Action {
    void run() throws Exception;
  }

  /**
   * The call's answer, or an AssertionError naming what failed, with the store's exception as its
   * cause.
   */
  static <T> T get(String what, Call<T> call) {
    try {
      return call.call();
    } catch (Exception e) {
      throw new AssertionError(what + ": the store threw " + e, e);
    }
  }

  static void must(String what, Action action) {
    try {
      action.run();
    } catch (Exception e) {
      throw new AssertionError(what + ": the store threw " + e, e);
    }
  }

  static void eq(String what, @Nullable Object got, @Nullable Object want) {
    if (!Objects.equals(got, want)) {
      throw new AssertionError(what + ":\n  got  " + got + "\n  want " + want);
    }
  }

  static List<String> ids(List<Run> runs) {
    List<String> out = new ArrayList<>();
    for (Run r : runs) {
      out.add(r.id());
    }
    return out;
  }

  static String json(@Nullable Run run) {
    return run == null ? "null" : run.toJson();
  }

  static String json(@Nullable JobState state) {
    return state == null ? "null" : state.toJson();
  }

  /**
   * JSON with every object's keys sorted, so two values compare whatever order a JSON column
   * (Postgres's JSONB) gave an object's keys back in. Text that is not JSON is itself.
   */
  static String canonical(String text) {
    try {
      return write(Json.parse(text));
    } catch (Json.JsonException e) {
      return text;
    }
  }

  private static String write(@Nullable Object v) {
    if (v instanceof JsObject o) {
      List<Map.Entry<String, @Nullable Object>> pairs = new ArrayList<>(o.entries());
      pairs.sort(Map.Entry.comparingByKey());
      List<String> body = new ArrayList<>();
      for (Map.Entry<String, @Nullable Object> e : pairs) {
        body.add(Json.quote(e.getKey()) + ":" + write(e.getValue()));
      }
      return "{" + String.join(",", body) + "}";
    }
    if (v instanceof List<?> list) {
      List<String> body = new ArrayList<>();
      for (Object x : list) {
        body.add(write(x));
      }
      return "[" + String.join(",", body) + "]";
    }
    return Json.stringify(v);
  }

  /** Two JSON texts are the same value, keys in any order. */
  static void sameJson(String what, String got, String want) {
    if (!canonical(got).equals(canonical(want))) {
      throw new AssertionError(what + ":\n  got  " + got + "\n  want " + want);
    }
  }
}
