package dev.cronwatch.internal.core;

import dev.cronwatch.Metrics;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.output.Output;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.concurrent.locks.ReentrantLock;
import org.jspecify.annotations.Nullable;

/**
 * {@code createRecorder} in the SDK's {@code job.ts}: the lines a run logs and the numbers it
 * reports. Safe to share, since a job may log from threads of its own.
 */
public final class Recorder {
  /**
   * How much logged text a recorder holds, in code units, before it drops lines from the front. The
   * cap trims exactly at the end, so this only bounds memory: well past the cap, so the kept tail
   * is whole.
   */
  static final int WINDOW = 64 * 1024;

  private final ReentrantLock lock = new ReentrantLock();
  private final ArrayDeque<String> lines = new ArrayDeque<>();
  private long size;
  private final List<String> head = new ArrayList<>();
  private long headSize;
  private boolean dropped;

  /** Set in place, as the SDK sets a metric: a copy per call made a run of many quadratic. */
  private final LinkedHashMap<String, Double> metrics = new LinkedHashMap<>();

  /** The metrics as last read, until another is reported. */
  private @Nullable Metrics read = Metrics.empty();

  /** An empty recorder. */
  public Recorder() {}

  /** Appends a line. */
  public void log(String line) {
    lock.lock();
    try {
      if (headSize < Output.OUTPUT_CAP) {
        head.add(line);
        headSize += line.length() + 1;
      }
      lines.addLast(line);
      size += line.length() + 1;
      // Drop from the front once well past the cap; redactAndCap trims exactly at the end.
      while (size > WINDOW && lines.size() > 1) {
        size -= lines.removeFirst().length() + 1;
        dropped = true;
      }
    } finally {
      lock.unlock();
    }
  }

  /**
   * The lines still held (past 64 KB the oldest are let go), joined and not yet capped: the client
   * redacts them first, then caps them ({@link Output#redactAndCap}). Null when nothing was logged.
   */
  public @Nullable String output() {
    lock.lock();
    try {
      return lines.isEmpty() ? null : String.join("\n", lines);
    } finally {
      lock.unlock();
    }
  }

  /**
   * What an expect rule is checked against: everything logged, or when that ran long, the first 16
   * KB and the last 16 KB. The stored output keeps only the tail, so a "done" line printed early
   * would otherwise be lost. Null when nothing was logged.
   */
  public @Nullable String expectText() {
    lock.lock();
    try {
      if (lines.isEmpty()) {
        return null;
      }
      String all = String.join("\n", lines);
      if (!dropped && all.length() <= 2 * Output.OUTPUT_CAP) {
        return all;
      }
      return Js.head(String.join("\n", head), Output.OUTPUT_CAP)
          + "\n"
          + Js.tail(all, Output.OUTPUT_CAP);
    } finally {
      lock.unlock();
    }
  }

  /**
   * Reports a number for the run; a later value for the same name replaces an earlier one.
   *
   * @throws IllegalArgumentException for a value that is not finite, with the SDK's message
   */
  public void metric(String name, double value) {
    if (!Double.isFinite(value)) {
      throw new IllegalArgumentException("metric \"" + name + "\" must be a finite number");
    }
    lock.lock();
    try {
      metrics.put(name, value);
      read = null;
    } finally {
      lock.unlock();
    }
  }

  /** The numbers reported, in JavaScript's key order. */
  public Metrics metrics() {
    lock.lock();
    try {
      Metrics m = read;
      if (m == null) {
        m = Metrics.of(metrics);
        read = m;
      }
      return m;
    } finally {
      lock.unlock();
    }
  }
}
