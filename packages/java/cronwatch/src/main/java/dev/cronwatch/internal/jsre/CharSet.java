package dev.cronwatch.internal.jsre;

import java.util.Arrays;
import java.util.Locale;
import org.jspecify.annotations.Nullable;

/**
 * A set of UTF-16 code units, held as its sorted ranges so a set costs a few integers however many
 * characters it holds (the Elixir audit: a set held as a bitmap per character made a long pattern
 * some 130 MB). A set built with the {@code i} flag matches a code unit when any member has the
 * same canonical form, as JavaScript's Canonicalize reads it without the {@code u} flag; a negated
 * set answers the opposite, after folding, as JavaScript's CharacterSetMatcher does.
 */
final class CharSet implements CharTest {
  private final int[] ranges;
  private final boolean negate;
  private final boolean fold;

  private CharSet(int[] ranges, boolean negate, boolean fold) {
    this.ranges = ranges;
    this.negate = negate;
    this.fold = fold;
  }

  /** Whether the set's own ranges hold {@code c}, before folding and negation. */
  private boolean raw(char c) {
    int lo = 0;
    int hi = ranges.length / 2 - 1;
    while (lo <= hi) {
      int mid = (lo + hi) >>> 1;
      if (c < ranges[2 * mid]) {
        hi = mid - 1;
      } else if (c > ranges[2 * mid + 1]) {
        lo = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  @Override
  public boolean has(char c) {
    boolean in = raw(c);
    if (!in && fold) {
      char[] same = Canonical.equivalents(c);
      if (same != null) {
        for (char x : same) {
          if (raw(x)) {
            in = true;
            break;
          }
        }
      }
    }
    return in != negate;
  }

  /** Adds every code unit the set holds to a bitmap of the whole range. */
  void addTo(long[] bits) {
    if (!negate && !fold) {
      for (int i = 0; i < ranges.length; i += 2) {
        for (int c = ranges[i]; c <= ranges[i + 1]; c++) {
          bits[c >> 6] |= 1L << (c & 63);
        }
      }
      return;
    }
    for (int c = 0; c <= 0xffff; c++) {
      if (has((char) c)) {
        bits[c >> 6] |= 1L << (c & 63);
      }
    }
  }

  @Override
  public boolean equals(@Nullable Object o) {
    return o instanceof CharSet s
        && s.negate == negate
        && s.fold == fold
        && Arrays.equals(s.ranges, ranges);
  }

  @Override
  public int hashCode() {
    return Arrays.hashCode(ranges) * 4 + (negate ? 2 : 0) + (fold ? 1 : 0);
  }

  /** A set being read from a pattern: ranges added in any order, merged when it is built. */
  static final class Builder {
    private int[] buf = new int[8];
    private int n;
    boolean negate;

    /** Adds one code unit. */
    Builder add(int c) {
      return addRange(c, c);
    }

    /** Adds the code units from {@code lo} to {@code hi}, both included. */
    Builder addRange(int lo, int hi) {
      if (n + 2 > buf.length) {
        buf = Arrays.copyOf(buf, buf.length * 2);
      }
      buf[n++] = lo;
      buf[n++] = hi;
      return this;
    }

    /** Adds sorted ranges, as {@link #complement} and the constants below give them. */
    Builder addAll(int[] ranges) {
      for (int i = 0; i < ranges.length; i += 2) {
        addRange(ranges[i], ranges[i + 1]);
      }
      return this;
    }

    /** Adds every member of another builder (its negation is not carried). */
    Builder union(Builder o) {
      return addAll(o.normalized());
    }

    /** The ranges sorted and merged. */
    int[] normalized() {
      int count = n / 2;
      long[] pairs = new long[count];
      for (int i = 0; i < count; i++) {
        pairs[i] = ((long) buf[2 * i] << 32) | buf[2 * i + 1];
      }
      Arrays.sort(pairs);
      int[] out = new int[n];
      int m = 0;
      for (long p : pairs) {
        int lo = (int) (p >>> 32);
        int hi = (int) p;
        if (m > 0 && lo <= out[m - 1] + 1) {
          out[m - 1] = Math.max(out[m - 1], hi);
        } else {
          out[m++] = lo;
          out[m++] = hi;
        }
      }
      return Arrays.copyOf(out, m);
    }

    /** The one code unit a set of exactly one plain member holds, or -1. */
    int single() {
      if (negate) {
        return -1;
      }
      int[] r = normalized();
      return r.length == 2 && r[0] == r[1] ? r[0] : -1;
    }

    /** The set, folded when the pattern has the {@code i} flag. */
    CharSet build(boolean fold) {
      return new CharSet(normalized(), negate, fold);
    }
  }

  /** The code units not in these sorted, merged ranges. */
  static int[] complement(int[] ranges) {
    int[] out = new int[ranges.length + 2];
    int m = 0;
    int from = 0;
    for (int i = 0; i < ranges.length; i += 2) {
      if (ranges[i] > from) {
        out[m++] = from;
        out[m++] = ranges[i] - 1;
      }
      from = ranges[i + 1] + 1;
    }
    if (from <= 0xffff) {
      out[m++] = from;
      out[m++] = 0xffff;
    }
    return Arrays.copyOf(out, m);
  }

  /** {@code \d}. */
  static final int[] DIGIT = {'0', '9'};

  /** {@code \w}: ASCII letters, digits, and underscore, whatever the flags. */
  static final int[] WORD = {'0', '9', 'A', 'Z', '_', '_', 'a', 'z'};

  /** JavaScript's {@code \s}: WhiteSpace and LineTerminator. */
  static final int[] SPACE = {
    0x09, 0x0d, 0x20, 0x20, 0xa0, 0xa0, 0x1680, 0x1680, 0x2000, 0x200a, 0x2028, 0x2029, 0x202f,
    0x202f, 0x205f, 0x205f, 0x3000, 0x3000, 0xfeff, 0xfeff
  };

  /** {@code .}: everything but a line terminator. */
  static final int[] DOT = complement(new int[] {0x0a, 0x0a, 0x0d, 0x0d, 0x2028, 0x2029});

  /**
   * JavaScript's Canonicalize without the {@code u} flag: a code unit's upper case when that is one
   * code unit, unless it maps a character outside ASCII onto one inside it, so the long s (U+017F)
   * never matches "s" and the Kelvin sign never matches "k".
   */
  static final class Canonical {
    private Canonical() {}

    private static final char[][] EQUIVALENTS = build();

    /** Every other code unit with the same canonical form as {@code c}, or null when none. */
    static char @Nullable [] equivalents(char c) {
      return EQUIVALENTS[c];
    }

    static char canonicalize(char c) {
      String upper = String.valueOf(c).toUpperCase(Locale.ROOT);
      if (upper.length() != 1) {
        return c;
      }
      char u = upper.charAt(0);
      return c >= 128 && u < 128 ? c : u;
    }

    private static char[][] build() {
      char[] canon = new char[0x10000];
      int[] count = new int[0x10000];
      for (int c = 0; c <= 0xffff; c++) {
        canon[c] = canonicalize((char) c);
        count[canon[c]]++;
      }
      char[][] members = new char[0x10000][];
      for (int c = 0; c <= 0xffff; c++) {
        int k = canon[c];
        if (count[k] > 1) {
          if (members[k] == null) {
            members[k] = new char[0];
          }
          char[] m = Arrays.copyOf(members[k], members[k].length + 1);
          m[m.length - 1] = (char) c;
          members[k] = m;
        }
      }
      char[][] out = new char[0x10000][];
      for (int c = 0; c <= 0xffff; c++) {
        char[] m = members[canon[c]];
        if (m != null) {
          char[] others = new char[m.length - 1];
          int j = 0;
          for (char x : m) {
            if (x != c) {
              others[j++] = x;
            }
          }
          out[c] = others;
        }
      }
      return out;
    }
  }
}
