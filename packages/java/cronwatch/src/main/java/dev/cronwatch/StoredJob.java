package dev.cronwatch;

import java.util.Objects;

/**
 * A job as a store knows it.
 *
 * @param name the job's name
 * @param definition its definition as last declared
 * @param createdAt when it was first declared, epoch milliseconds
 * @param updatedAt when it was last declared
 */
public record StoredJob(String name, Definition definition, long createdAt, long updatedAt) {
  /** Checks that the components are there. */
  public StoredJob {
    Objects.requireNonNull(name, "name");
    Objects.requireNonNull(definition, "definition");
  }
}
