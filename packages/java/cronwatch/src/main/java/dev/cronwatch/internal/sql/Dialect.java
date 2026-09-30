package dev.cronwatch.internal.sql;

/**
 * The database's SQL: SQLite's and Postgres's are the SDK's {@code stores/sql.ts}, text for text;
 * MySQL's (and MariaDB's) is the PHP, Go, Rust and Elixir ports' own.
 */
public enum Dialect {
  /** SQLite, as the SDK's {@code sqlite()} store writes it. */
  SQLITE("sqlite"),
  /** Postgres, as the SDK's {@code postgres()} store writes it. */
  POSTGRES("postgres"),
  /**
   * MySQL 8.0.13 or newer, or MariaDB 10.6 or newer, as the Go port's {@code sqlstore} writes it.
   */
  MYSQL("mysql");

  private final String label;

  Dialect(String label) {
    this.label = label;
  }

  /** The dialect's name as the SDK writes it: {@code sqlite}, {@code postgres} or {@code mysql}. */
  public String label() {
    return label;
  }
}
