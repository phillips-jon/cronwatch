package dev.cronwatch;

import java.lang.reflect.Method;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/**
 * The failure a value a job returned fails its run with: an HTTP answer of 400 or more ({@code HTTP
 * 503 Service Unavailable}), as the SDK fails a run for a fetch {@code Response}. The JDK's {@code
 * java.net.http.HttpResponse} and Spring's {@code ResponseEntity} are found by name, so the core
 * needs neither; the reason is RFC 9110's, since neither carries one.
 */
final class Http {
  private Http() {}

  private static final Map<Integer, String> REASONS =
      Map.ofEntries(
          Map.entry(400, "Bad Request"),
          Map.entry(401, "Unauthorized"),
          Map.entry(402, "Payment Required"),
          Map.entry(403, "Forbidden"),
          Map.entry(404, "Not Found"),
          Map.entry(405, "Method Not Allowed"),
          Map.entry(406, "Not Acceptable"),
          Map.entry(407, "Proxy Authentication Required"),
          Map.entry(408, "Request Timeout"),
          Map.entry(409, "Conflict"),
          Map.entry(410, "Gone"),
          Map.entry(411, "Length Required"),
          Map.entry(412, "Precondition Failed"),
          Map.entry(413, "Content Too Large"),
          Map.entry(414, "URI Too Long"),
          Map.entry(415, "Unsupported Media Type"),
          Map.entry(416, "Range Not Satisfiable"),
          Map.entry(417, "Expectation Failed"),
          Map.entry(421, "Misdirected Request"),
          Map.entry(422, "Unprocessable Content"),
          Map.entry(426, "Upgrade Required"),
          Map.entry(500, "Internal Server Error"),
          Map.entry(501, "Not Implemented"),
          Map.entry(502, "Bad Gateway"),
          Map.entry(503, "Service Unavailable"),
          Map.entry(504, "Gateway Timeout"),
          Map.entry(505, "HTTP Version Not Supported"));

  /** {@code HTTP <status> <reason>} for a status of 400 or more, else null. */
  static @Nullable String failureText(int status) {
    if (status < 400) {
      return null;
    }
    String reason = REASONS.get(status);
    return reason == null ? "HTTP " + status : "HTTP " + status + " " + reason;
  }

  /** The failure a returned value fails its run with, or null for any other value. */
  static @Nullable String failure(@Nullable Object value) {
    Integer status = status(value);
    return status == null ? null : failureText(status);
  }

  /** The HTTP status of a dashboard, JDK, or Spring answer, or null. */
  static @Nullable Integer status(@Nullable Object value) {
    if (value == null) {
      return null;
    }
    if (value instanceof dev.cronwatch.web.Response r) {
      return r.status();
    }
    try {
      Class<?> jdk = implemented(value.getClass(), "java.net.http.HttpResponse");
      if (jdk != null) {
        return (Integer) jdk.getMethod("statusCode").invoke(value);
      }
      Class<?> spring = superclass(value.getClass(), "org.springframework.http.ResponseEntity");
      if (spring != null) {
        Object code = spring.getMethod("getStatusCode").invoke(value);
        Method v = implementedMethod(code, "org.springframework.http.HttpStatusCode", "value");
        return v == null ? null : (Integer) v.invoke(code);
      }
    } catch (ReflectiveOperationException | RuntimeException | LinkageError e) {
      return null;
    }
    return null;
  }

  private static @Nullable Class<?> implemented(Class<?> c, String name) {
    for (Class<?> k = c; k != null; k = k.getSuperclass()) {
      for (Class<?> i : k.getInterfaces()) {
        if (i.getName().equals(name)) {
          return i;
        }
        Class<?> deeper = implemented(i, name);
        if (deeper != null) {
          return deeper;
        }
      }
    }
    return null;
  }

  private static @Nullable Class<?> superclass(Class<?> c, String name) {
    for (Class<?> k = c; k != null; k = k.getSuperclass()) {
      if (k.getName().equals(name)) {
        return k;
      }
    }
    return null;
  }

  private static @Nullable Method implementedMethod(@Nullable Object value, String type, String m)
      throws NoSuchMethodException {
    if (value == null) {
      return null;
    }
    Class<?> i = implemented(value.getClass(), type);
    return i == null ? null : i.getMethod(m);
  }
}
