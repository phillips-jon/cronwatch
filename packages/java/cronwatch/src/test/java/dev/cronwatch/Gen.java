package dev.cronwatch;

import java.util.List;
import java.util.SplittableRandom;
import java.util.function.Consumer;

/**
 * The properties' inputs: a seeded generator, so a failing case names the seed that makes it again.
 * Each property runs its number of tries, each from a seed of its own; {@code -Dcronwatch.tries=N}
 * multiplies them, for a longer run.
 */
public final class Gen {
  private final SplittableRandom random;

  private Gen(long seed) {
    this.random = new SplittableRandom(seed);
  }

  /**
   * Runs {@code property} {@code tries} times (multiplied by {@code cronwatch.tries}), each with a
   * generator of its own seed, and names the seed of a case that fails.
   */
  public static void check(long seed, int tries, Consumer<Gen> property) {
    int times = tries * Integer.getInteger("cronwatch.tries", 1);
    for (int i = 0; i < times; i++) {
      long s = seed * 1_000_003L + i;
      try {
        property.accept(new Gen(s));
      } catch (RuntimeException | AssertionError e) {
        throw new AssertionError("case " + i + " (seed " + s + ") failed: " + e.getMessage(), e);
      }
    }
  }

  /** A whole number from {@code min} to {@code max}, both included. */
  public long between(long min, long max) {
    return max == Long.MAX_VALUE && min == Long.MIN_VALUE
        ? random.nextLong()
        : min + (long) (random.nextDouble() * ((double) max - (double) min + 1));
  }

  /** Any long, the extremes and small numbers more often than chance. */
  public long anyLong() {
    return switch (random.nextInt(8)) {
      case 0 -> Long.MIN_VALUE;
      case 1 -> Long.MAX_VALUE;
      case 2 -> random.nextInt(2001) - 1000;
      default -> random.nextLong();
    };
  }

  /** Any double, the special values and whole numbers more often than chance. */
  public double anyDouble() {
    return switch (random.nextInt(10)) {
      case 0 -> Double.NaN;
      case 1 -> Double.POSITIVE_INFINITY;
      case 2 -> Double.NEGATIVE_INFINITY;
      case 3 -> -0.0;
      case 4 -> Double.MIN_VALUE;
      case 5 -> random.nextInt(2_000_001) - 1_000_000;
      case 6 -> Double.longBitsToDouble(random.nextLong());
      default -> (random.nextDouble() - 0.5) * Math.pow(10, random.nextInt(40) - 20);
    };
  }

  /** A coin toss. */
  public boolean bool() {
    return random.nextBoolean();
  }

  /** One of the choices. */
  public <T> T oneOf(List<T> choices) {
    return choices.get(random.nextInt(choices.size()));
  }

  /**
   * Any text up to {@code max} UTF-16 units: ASCII, control characters, JSON's and JavaScript's
   * punctuation, letters outside ASCII, whole pairs, and lone halves of surrogates.
   */
  public String anyString(int max) {
    int n = random.nextInt(max + 1);
    StringBuilder b = new StringBuilder(n);
    while (b.length() < n) {
      switch (random.nextInt(8)) {
        case 0 -> b.append((char) random.nextInt(0x20));
        case 1 -> b.append("\"\\{}[]:,/'`$".charAt(random.nextInt(12)));
        case 2 -> b.append((char) (0xa0 + random.nextInt(0x2f00)));
        case 3 -> b.append((char) (0xd800 + random.nextInt(0x800)));
        case 4 -> b.append("\ud83d\ude00");
        case 5 -> b.append((char) (0xe000 + random.nextInt(0x2000)));
        default -> b.append((char) (0x20 + random.nextInt(0x5f)));
      }
    }
    return b.toString();
  }

  /** Text of up to {@code max} characters drawn from {@code chars}. */
  public String stringOf(String chars, int max) {
    int n = random.nextInt(max + 1);
    StringBuilder b = new StringBuilder(n);
    for (int i = 0; i < n; i++) {
      b.append(chars.charAt(random.nextInt(chars.length())));
    }
    return b.toString();
  }

  /** Up to {@code max} of the pieces, joined. */
  public String joined(List<String> pieces, int max) {
    int n = random.nextInt(max + 1);
    StringBuilder b = new StringBuilder();
    for (int i = 0; i < n; i++) {
      b.append(pieces.get(random.nextInt(pieces.size())));
    }
    return b.toString();
  }
}
