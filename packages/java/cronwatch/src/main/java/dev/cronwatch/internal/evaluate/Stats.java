package dev.cronwatch.internal.evaluate;

import java.util.Arrays;
import java.util.List;
import org.jspecify.annotations.Nullable;

/** Percentile and median (the SDK's {@code stats.ts}). */
public final class Stats {
  private Stats() {}

  private static double[] sorted(List<Double> values) {
    double[] out = new double[values.size()];
    for (int i = 0; i < out.length; i++) {
      out[i] = values.get(i);
    }
    Arrays.sort(out);
    return out;
  }

  /**
   * The nearest-rank value, with the rank worked out in the same floating point steps as
   * JavaScript's, so a Java and a Node process pick the same run; null for no values.
   */
  public static @Nullable Double percentile(List<Double> values, double p) {
    if (values.isEmpty()) {
      return null;
    }
    double[] s = sorted(values);
    double n = s.length;
    int index = (int) Math.min(n - 1, Math.max(0, Math.ceil((p / 100) * n) - 1));
    return s[index];
  }

  /** The middle value, or the mean of the two in the middle; null for no values. */
  public static @Nullable Double median(List<Double> values) {
    if (values.isEmpty()) {
      return null;
    }
    double[] s = sorted(values);
    int mid = s.length / 2;
    return s.length % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid];
  }
}
