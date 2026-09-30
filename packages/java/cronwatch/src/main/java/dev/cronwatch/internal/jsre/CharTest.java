package dev.cronwatch.internal.jsre;

import java.util.List;

/** What a code unit must be at some point of a match: a set, or the union of several. */
interface CharTest {
  /** Whether {@code c} is one. */
  boolean has(char c);

  /** The union of several tests. */
  static CharTest anyOf(List<CharTest> parts) {
    CharTest[] all = parts.toArray(new CharTest[0]);
    return c -> {
      for (CharTest p : all) {
        if (p.has(c)) {
          return true;
        }
      }
      return false;
    };
  }
}
