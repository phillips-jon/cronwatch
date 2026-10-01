package dev.cronwatch.json;

import dev.cronwatch.internal.js.Js;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/**
 * {@code JSON.stringify} and {@code JSON.parse}, byte for byte, for everything CronWatch writes to
 * a store or reads from one, so a Java process and a Node, Ruby, Python, PHP, Go, Rust or Elixir
 * process can share one database.
 *
 * <p>Numbers are written as JavaScript prints them ({@code 2}, not {@code 2.0}; {@code 1e-7};
 * {@code 1e+21}), a number that is not finite as {@code null}, and a {@code long} beyond 2^53 as
 * the double JavaScript would hold. Strings escape only control characters, quotes and backslashes,
 * and a lone surrogate as {@code \ud83d}, as a well-formed {@code JSON.stringify} does. Objects
 * keep JavaScript's key order (see {@link JsObject}).
 */
public final class Json {
  /**
   * How deep arrays and objects may nest: 256. The reader and writer recurse, so text nested
   * thousands deep (a request body, a stored row) would overflow a thread's stack; nothing
   * CronWatch or an app stores comes near this.
   */
  private static final int MAX_DEPTH = Js.JSON_MAX_DEPTH;

  private Json() {}

  /** Why text is not JSON, with {@code JSON.parse}'s wording and the position in UTF-16 units. */
  public static final class JsonException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    /** An error with this message. */
    public JsonException(String message) {
      super(message);
    }
  }

  /**
   * {@code JSON.stringify} of a value: {@code null}, a {@link Boolean}, a {@link Number}, a {@link
   * CharSequence}, a {@link List}, a {@link JsObject} or a {@link Map} (written in its iteration
   * order, as an object literal would be; array-index keys first, as JavaScript orders them).
   *
   * @throws IllegalArgumentException for a value of any other type
   */
  public static String stringify(@Nullable Object value) {
    StringBuilder b = new StringBuilder();
    write(b, value, 0);
    return b.toString();
  }

  private static void write(StringBuilder b, @Nullable Object v, int depth) {
    if (depth > MAX_DEPTH) {
      throw new IllegalArgumentException("JSON nested too deeply");
    }
    switch (v) {
      case null -> b.append("null");
      case Boolean bool -> b.append(bool ? "true" : "false");
      case Double d -> b.append(Double.isFinite(d) ? Js.formatNumber(d) : "null");
      case Float f -> b.append(Float.isFinite(f) ? Js.formatNumber(f.doubleValue()) : "null");
      case Long l -> b.append(Js.formatLong(l));
      case Integer i -> b.append(i.intValue());
      case Short s -> b.append(s.intValue());
      case Byte y -> b.append(y.intValue());
      case Number n -> {
        double d = n.doubleValue();
        b.append(Double.isFinite(d) ? Js.formatNumber(d) : "null");
      }
      case CharSequence s -> quoteInto(b, s.toString());
      case JsObject o -> {
        b.append('{');
        boolean first = true;
        for (Map.Entry<String, @Nullable Object> e : o.entries()) {
          if (!first) {
            b.append(',');
          }
          first = false;
          quoteInto(b, e.getKey());
          b.append(':');
          write(b, e.getValue(), depth + 1);
        }
        b.append('}');
      }
      case Map<?, ?> m -> {
        JsObject o = new JsObject();
        for (Map.Entry<?, ?> e : m.entrySet()) {
          o.set(String.valueOf(e.getKey()), e.getValue());
        }
        write(b, o, depth);
      }
      case List<?> list -> {
        b.append('[');
        for (int i = 0; i < list.size(); i++) {
          if (i > 0) {
            b.append(',');
          }
          write(b, list.get(i), depth + 1);
        }
        b.append(']');
      }
      default ->
          throw new IllegalArgumentException(
              "cannot write a " + v.getClass().getName() + " as JSON");
    }
  }

  private static final char[] HEX = "0123456789abcdef".toCharArray();

  private static void quoteInto(StringBuilder b, String s) {
    b.append('"');
    int n = s.length();
    int start = 0;
    for (int i = 0; i < n; i++) {
      char c = s.charAt(i);
      if (c >= 0x20 && c != '"' && c != '\\' && !Character.isSurrogate(c)) {
        continue;
      }
      if (Character.isHighSurrogate(c) && i + 1 < n && Character.isLowSurrogate(s.charAt(i + 1))) {
        i++;
        continue;
      }
      String esc =
          switch (c) {
            case '"' -> "\\\"";
            case '\\' -> "\\\\";
            case '\b' -> "\\b";
            case '\f' -> "\\f";
            case '\n' -> "\\n";
            case '\r' -> "\\r";
            case '\t' -> "\\t";
            default ->
                "\\u"
                    + HEX[(c >> 12) & 0xf]
                    + HEX[(c >> 8) & 0xf]
                    + HEX[(c >> 4) & 0xf]
                    + HEX[c & 0xf];
          };
      b.append(s, start, i).append(esc);
      start = i + 1;
    }
    b.append(s, start, n);
    b.append('"');
  }

  /**
   * {@code JSON.parse}: numbers as {@link Double}, objects as {@link JsObject} in JavaScript's key
   * order (a key given twice keeps its first place and its last value), arrays as {@link List}. A
   * lone surrogate escape ({@code \ud800}) is kept, as JavaScript keeps it. Arrays and objects
   * nested more than 256 deep are refused.
   *
   * @throws JsonException when the text is not JSON
   */
  public static @Nullable Object parse(String text) {
    Parser p = new Parser(text);
    p.space();
    Object v = p.value(0);
    p.space();
    if (p.i < text.length()) {
      throw p.fail("Unexpected non-whitespace character after JSON");
    }
    return v;
  }

  /**
   * {@link #parse} of text that must be an object.
   *
   * @throws JsonException when the text is not JSON or not an object
   */
  public static JsObject parseObject(String text) {
    Object v = parse(text);
    if (v instanceof JsObject o) {
      return o;
    }
    throw new JsonException("expected a JSON object, not " + Js.typeOf(v));
  }

  private static final class Parser {
    private final String s;
    int i;

    Parser(String s) {
      this.s = s;
    }

    JsonException fail(String what) {
      return new JsonException(what + " at position " + i);
    }

    void space() {
      while (i < s.length()) {
        char c = s.charAt(i);
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r') {
          return;
        }
        i++;
      }
    }

    boolean at(char c) {
      return i < s.length() && s.charAt(i) == c;
    }

    @Nullable Object value(int depth) {
      if (depth >= MAX_DEPTH) {
        throw new JsonException("JSON nested too deeply");
      }
      if (i >= s.length()) {
        throw fail("Unexpected end of JSON input");
      }
      char c = s.charAt(i);
      switch (c) {
        case '{' -> {
          i++;
          JsObject o = new JsObject();
          space();
          if (at('}')) {
            i++;
            return o;
          }
          while (true) {
            space();
            if (!at('"')) {
              throw fail("Expected property name");
            }
            String k = string();
            space();
            if (!at(':')) {
              throw fail("Expected ':' after property name");
            }
            i++;
            space();
            Object v = value(depth + 1);
            o.set(k, v);
            space();
            if (at(',')) {
              i++;
              continue;
            }
            if (at('}')) {
              i++;
              return o;
            }
            throw fail("Expected ',' or '}' after property value");
          }
        }
        case '[' -> {
          i++;
          List<@Nullable Object> out = new ArrayList<>();
          space();
          if (at(']')) {
            i++;
            return out;
          }
          while (true) {
            space();
            out.add(value(depth + 1));
            space();
            if (at(',')) {
              i++;
              continue;
            }
            if (at(']')) {
              i++;
              return out;
            }
            throw fail("Expected ',' or ']' after array element");
          }
        }
        case '"' -> {
          return string();
        }
        case 't' -> {
          if (s.startsWith("true", i)) {
            i += 4;
            return true;
          }
          throw fail("Unexpected token");
        }
        case 'f' -> {
          if (s.startsWith("false", i)) {
            i += 5;
            return false;
          }
          throw fail("Unexpected token");
        }
        case 'n' -> {
          if (s.startsWith("null", i)) {
            i += 4;
            return null;
          }
          throw fail("Unexpected token");
        }
        default -> {
          if (c == '-' || (c >= '0' && c <= '9')) {
            return number();
          }
          throw fail("Unexpected token");
        }
      }
    }

    int digits() {
      int from = i;
      while (i < s.length() && s.charAt(i) >= '0' && s.charAt(i) <= '9') {
        i++;
      }
      return i - from;
    }

    Double number() {
      int start = i;
      if (at('-')) {
        i++;
      }
      if (at('0')) {
        i++;
      } else if (digits() == 0) {
        throw fail("No number after minus sign");
      }
      if (at('.')) {
        i++;
        if (digits() == 0) {
          throw fail("Unterminated fractional number");
        }
      }
      if (at('e') || at('E')) {
        i++;
        if (at('+') || at('-')) {
          i++;
        }
        if (digits() == 0) {
          throw fail("Exponent part is missing a number");
        }
      }
      // Out of range reads as JavaScript reads it: Infinity or 0.
      return Double.parseDouble(s.substring(start, i));
    }

    int hex4() {
      if (i + 4 > s.length()) {
        return -1;
      }
      int n = 0;
      for (int k = 0; k < 4; k++) {
        int d = Character.digit(s.charAt(i + k), 16);
        if (d < 0 || s.charAt(i + k) > 'f') {
          return -1;
        }
        n = n * 16 + d;
      }
      i += 4;
      return n;
    }

    String string() {
      i++; // the opening quote
      StringBuilder b = new StringBuilder();
      int start = i;
      while (i < s.length()) {
        char c = s.charAt(i);
        if (c == '"') {
          b.append(s, start, i);
          i++;
          return b.toString();
        }
        if (c < 0x20) {
          throw fail("Bad control character in string literal");
        }
        if (c == '\\') {
          b.append(s, start, i);
          i++;
          if (i >= s.length()) {
            throw fail("Unterminated string");
          }
          char e = s.charAt(i++);
          switch (e) {
            case '"', '\\', '/' -> b.append(e);
            case 'b' -> b.append('\b');
            case 'f' -> b.append('\f');
            case 'n' -> b.append('\n');
            case 'r' -> b.append('\r');
            case 't' -> b.append('\t');
            case 'u' -> {
              int u = hex4();
              if (u < 0) {
                throw fail("Bad Unicode escape");
              }
              b.append((char) u);
            }
            default -> throw fail("Bad escaped character");
          }
          start = i;
          continue;
        }
        i++;
      }
      throw fail("Unterminated string");
    }
  }
}
