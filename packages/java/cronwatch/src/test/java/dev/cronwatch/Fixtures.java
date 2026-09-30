package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import org.jspecify.annotations.Nullable;

/**
 * What the replays of {@code conformance/*.json} share: reading a fixture in JavaScript's key
 * order, the recipes for long text, the digests of long results, and a collector that reports every
 * case that differs at once.
 */
public final class Fixtures {
  private Fixtures() {}

  /** The repository's root, which Surefire passes as {@code cronwatch.repo}. */
  public static Path repo() {
    String dir = System.getProperty("cronwatch.repo");
    if (dir == null) {
      // Run from the IDE without Surefire's settings: packages/java/cronwatch is the directory.
      return Path.of("../../..").toAbsolutePath().normalize();
    }
    return Path.of(dir).toAbsolutePath().normalize();
  }

  /** The repository's {@code conformance/} directory. */
  public static Path conformanceDir() {
    return repo().resolve("conformance");
  }

  /** {@code conformance/<name>.json}, in JavaScript's key order. */
  public static JsObject load(String name) {
    Path path = conformanceDir().resolve(name + ".json");
    try {
      return Json.parseObject(Files.readString(path, StandardCharsets.UTF_8));
    } catch (IOException e) {
      throw new UncheckedIOException(path.toString(), e);
    }
  }

  /** {@code o[key]} as a list of objects. */
  public static List<JsObject> objects(JsObject o, String key) {
    List<JsObject> out = new ArrayList<>();
    if (o.get(key) instanceof List<?> list) {
      for (Object v : list) {
        if (v instanceof JsObject x) {
          out.add(x);
        }
      }
    }
    return out;
  }

  /** {@code o[key]} as a list. */
  public static List<?> list(JsObject o, String key) {
    return o.get(key) instanceof List<?> list ? list : List.of();
  }

  /** {@code o[key]} as an object, or an empty one. */
  public static JsObject object(JsObject o, String key) {
    return o.get(key) instanceof JsObject x ? x : new JsObject();
  }

  /** {@code o[key]} as a string, or null. */
  public static @Nullable String string(JsObject o, String key) {
    return o.get(key) instanceof String s ? s : null;
  }

  /** {@code o[key]} as a whole number, truncated as the ports hold times; NaN (absent) as 0. */
  public static long integer(JsObject o, String key) {
    return o.get(key) instanceof Number n ? Js.toLong(n.doubleValue()) : 0;
  }

  /** {@code o[key]} as a whole number, or null when it is not a number. */
  public static @Nullable Long optInteger(JsObject o, String key) {
    return o.get(key) instanceof Number n ? Js.toLong(n.doubleValue()) : null;
  }

  /** {@code o[key]} as a double, or NaN. */
  public static double number(JsObject o, String key) {
    return o.get(key) instanceof Number n ? n.doubleValue() : Double.NaN;
  }

  /**
   * The fixtures' recipe for long text: a string, or {@code {parts: [[piece, times], ...]}} joined.
   */
  public static String expand(@Nullable Object spec) {
    if (spec instanceof String s) {
      return s;
    }
    if (!(spec instanceof JsObject o)) {
      throw new IllegalArgumentException("not a text recipe: " + Json.stringify(spec));
    }
    StringBuilder b = new StringBuilder();
    for (Object p : list(o, "parts")) {
      List<?> pair = (List<?>) p;
      b.append(((String) pair.get(0)).repeat(((Number) pair.get(1)).intValue()));
    }
    return b.toString();
  }

  /** SHA-256 of the text's UTF-8 (a lone surrogate as U+FFFD), as lowercase hex. */
  public static String sha256Hex(String text) {
    return sha256Hex(Js.utf8(text));
  }

  /** SHA-256 as lowercase hex. */
  public static String sha256Hex(byte[] data) {
    try {
      return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(data));
    } catch (NoSuchAlgorithmException e) {
      throw new IllegalStateException(e);
    }
  }

  /**
   * The fixtures' form of a long result: {@code {text}} up to 400 UTF-16 code units, else {@code
   * {length, sha256}}; null stays null.
   */
  public static @Nullable JsObject digest(@Nullable String text) {
    if (text == null) {
      return null;
    }
    if (text.length() <= 400) {
      return new JsObject().set("text", text);
    }
    return new JsObject().set("length", text.length()).set("sha256", sha256Hex(text));
  }

  /**
   * Collects every case that is not the SDK's JSON, byte for byte, so a replay reports them all.
   */
  public static final class Failures {
    private final List<String> failures = new ArrayList<>();

    /** An empty collector. */
    public Failures() {}

    /** Records a difference when the two values' JSON differ. */
    public void same(String what, @Nullable Object got, @Nullable Object want) {
      String g = Json.stringify(got);
      String w = Json.stringify(want);
      if (!g.equals(w)) {
        failures.add(what + ":\n  got  " + clip(g) + "\n  want " + clip(w));
      }
    }

    /** Records a failure. */
    public void fail(String what) {
      failures.add(what);
    }

    /** Fails the test when any case differed. */
    public void check(String fixture) {
      assertTrue(
          failures.isEmpty(),
          () ->
              fixture
                  + ".json: "
                  + failures.size()
                  + " cases differ:\n"
                  + String.join("\n", failures.subList(0, Math.min(failures.size(), 40))));
    }

    private static String clip(String s) {
      return s.length() > 600 ? s.substring(0, 600) + "..." : s;
    }
  }
}
