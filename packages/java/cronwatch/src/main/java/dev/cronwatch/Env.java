package dev.cronwatch;

import java.util.Locale;
import org.jspecify.annotations.Nullable;

/**
 * The environment, read in one place, when used. The SDK reads {@code NODE_ENV}; Java has no
 * convention of its own, so CronWatch's own variable comes first, then {@code APP_ENV}, as the Go,
 * PHP, Rust and Elixir ports read them.
 */
final class Env {
  /** Where the client's own warnings and default error handler write. */
  static final System.Logger LOGGER = System.getLogger("dev.cronwatch");

  private static final String[] VARIABLES = {"CRONWATCH_ENV", "APP_ENV"};

  private Env() {}

  /**
   * The environment's name, lowercased, or {@code ""} when no variable names one. {@code
   * development}, {@code dev}, {@code local}, {@code test} and {@code testing} count as {@code
   * development} and {@code prod} as {@code production}. An unset environment is not development,
   * which is the safe reading.
   */
  static String environment() {
    return environment(null);
  }

  /**
   * {@link #environment()}, or {@code fallback} (read the same way) when no variable names one: the
   * Spring starter's, from the app's active profiles.
   */
  static String environment(@Nullable String fallback) {
    for (String name : VARIABLES) {
      String value = System.getenv(name);
      if (value == null) {
        continue;
      }
      String v = normalize(value);
      if (!v.isEmpty()) {
        return v;
      }
    }
    return fallback == null ? "" : normalize(fallback);
  }

  private static String normalize(String value) {
    String v = value.strip().toLowerCase(Locale.ROOT);
    return switch (v) {
      case "prod" -> "production";
      case "dev", "local", "test", "testing" -> "development";
      default -> v;
    };
  }

  /** A variable's value, or null when it is unset. */
  static String read(String name) {
    return System.getenv(name);
  }
}
