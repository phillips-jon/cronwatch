package dev.cronwatch.internal.jsre;

import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.internal.output.Output;
import net.jqwik.api.Arbitraries;
import net.jqwik.api.Arbitrary;
import net.jqwik.api.ForAll;
import net.jqwik.api.Property;
import net.jqwik.api.Provide;

/**
 * A stored expect pattern is a door untrusted input comes through: any process sharing the store
 * writes one, and every other reads it back. Whatever the pattern and the output, compiling refuses
 * with an IllegalArgumentException or succeeds, and a test or a replacement within the budget
 * answers or gives up, never throws and never runs on. Redaction takes any text.
 */
class RegexpProperties {
  @Provide
  Arbitrary<String> patterns() {
    Arbitrary<String> pieces =
        Arbitraries.of(
            "a", "b", "x", ".", "\\d", "\\s", "\\w", "\\b", "\\B", "^", "$", "[a-c]", "[^b]", "(",
            ")", "(?:", "(?=", "(?!", "(?<=", "(?<!", "|", "*", "+", "?", "{2}", "{1,3}", "{2,}",
            "\\", "]", "[", "-", "é", "\ud83d", "\ude00", "\\u0041", "\\x4");
    return pieces.list().ofMaxSize(24).map(list -> String.join("", list));
  }

  @Provide
  Arbitrary<String> outputs() {
    return Arbitraries.strings().withChars("abx\n Éé😀-").ofMaxLength(400);
  }

  @Property(tries = 1000)
  void aStoredPatternAnswersOrGivesUp(
      @ForAll("patterns") String source, @ForAll("outputs") String output, @ForAll boolean fold) {
    Regexp re;
    try {
      re = Regexp.compile(source, fold ? "gi" : "g");
    } catch (IllegalArgumentException e) {
      return;
    }
    long started = System.nanoTime();
    re.tryTest(output);
    re.tryReplace(output, "[$1$&$$]");
    assertTrue(System.nanoTime() - started < 30_000_000_000L, "within 30 seconds");
  }

  @Property(tries = 300)
  void anyPatternTextCompilesOrIsRefused(@ForAll String source, @ForAll String output) {
    try {
      Regexp re = Regexp.compile(source, "");
      re.tryTest(output);
    } catch (IllegalArgumentException e) {
      // Refused, as it should be when it cannot be read.
    }
  }

  @Property(tries = 500)
  void redactionTakesAnyText(@ForAll String text) {
    String out = Output.redactSecrets(text);
    assertTrue(out.length() <= text.length() + 16 * Output.REDACTED.length() * 64);
  }
}
