package dev.cronwatch.internal.jsre;

import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.Gen;
import dev.cronwatch.internal.output.Output;
import java.util.List;
import org.junit.jupiter.api.Test;

/**
 * A stored expect pattern is a door untrusted input comes through: any process sharing the store
 * writes one, and every other reads it back. Whatever the pattern and the output, compiling refuses
 * with an IllegalArgumentException or succeeds, and a test or a replacement within the budget
 * answers or gives up, never throws and never runs on. Redaction takes any text.
 */
class RegexpProperties {
  private static final List<String> PIECES =
      List.of(
          "a", "b", "x", ".", "\\d", "\\s", "\\w", "\\b", "\\B", "^", "$", "[a-c]", "[^b]", "(",
          ")", "(?:", "(?=", "(?!", "(?<=", "(?<!", "|", "*", "+", "?", "{2}", "{1,3}", "{2,}",
          "\\", "]", "[", "-", "é", "\ud83d", "\ude00", "\\u0041", "\\x4");

  @Test
  void aStoredPatternAnswersOrGivesUp() {
    Gen.check(
        11,
        1000,
        g -> {
          String source = g.joined(PIECES, 24);
          String output = g.stringOf("abx\n Éé😀-", 400);
          Regexp re;
          try {
            re = Regexp.compile(source, g.bool() ? "gi" : "g");
          } catch (IllegalArgumentException e) {
            return;
          }
          long started = System.nanoTime();
          re.tryTest(output);
          re.tryReplace(output, "[$1$&$$]");
          assertTrue(System.nanoTime() - started < 30_000_000_000L, "within 30 seconds");
        });
  }

  @Test
  void anyPatternTextCompilesOrIsRefused() {
    Gen.check(
        12,
        300,
        g -> {
          try {
            Regexp re = Regexp.compile(g.anyString(40), "");
            re.tryTest(g.anyString(200));
          } catch (IllegalArgumentException e) {
            // Refused, as it should be when it cannot be read.
          }
        });
  }

  @Test
  void redactionTakesAnyText() {
    Gen.check(
        13,
        500,
        g -> {
          String text = g.anyString(300);
          String out = Output.redactSecrets(text);
          assertTrue(out.length() <= text.length() + 16 * Output.REDACTED.length() * 64);
        });
  }
}
