package dev.cronwatch.internal.sql;

/**
 * The database's SQL: SQLite's and Postgres's are the SDK's {@code stores/sql.ts}, text for text.
 */
public enum Dialect {
  /** SQLite, as the SDK's {@code sqlite()} store writes it. */
  SQLITE("sqlite"),
  /** Postgres, as the SDK's {@code postgres()} store writes it. */
  POSTGRES("postgres");

  private final String label;

  Dialect(String label) {
    this.label = label;
  }

  /** The dialect's name as the SDK writes it: {@code sqlite} or {@code postgres}. */
  public String label() {
    return label;
  }
}
