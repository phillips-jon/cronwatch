package dev.cronwatch;

import java.util.Objects;

/**
 * A job as a store knows it.
 *
 * <p>Build one with {@link #of}, not the canonical constructor: a record that may grow gains a
 * component in a minor release, which changes its constructor, while {@code of} keeps its
 * parameters and gives the new component its default.
 *
 * @param name the job's name
 * @param definition its definition as last declared
 * @param createdAt when it was first declared, epoch milliseconds
 * @param updatedAt when it was last declared
 */
public record StoredJob(String name, Definition definition, long createdAt, long updatedAt) {
  /** A job as a store reads one back. */
  public static StoredJob of(String name, Definition definition, long createdAt, long updatedAt) {
    return new StoredJob(name, definition, createdAt, updatedAt);
  }

  /** Checks that the components are there. */
  public StoredJob {
    Objects.requireNonNull(name, "name");
    Objects.requireNonNull(definition, "definition");
  }
}
