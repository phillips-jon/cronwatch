package dev.cronwatch;

import java.util.Locale;

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
    for (String name : VARIABLES) {
      String value = System.getenv(name);
      if (value == null) {
        continue;
      }
      String v = value.strip().toLowerCase(Locale.ROOT);
      if (v.isEmpty()) {
        continue;
      }
      return switch (v) {
        case "prod" -> "production";
        case "dev", "local", "test", "testing" -> "development";
        default -> v;
      };
    }
    return "";
  }

  /** A variable's value, or null when it is unset. */
  static String read(String name) {
    return System.getenv(name);
  }
}
