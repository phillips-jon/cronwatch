package dev.cronwatch.internal.jsre;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;

/**
 * JavaScript's semantics the redaction and expect patterns rely on, each checked against what V8
 * answers for the same pattern and input (written beside each case as the JavaScript expression it
 * mirrors).
 */
class RegexpTest {
  private static String replace(String source, String flags, String input, String template) {
    return Regexp.compile(source, flags).replace(input, template);
  }

  @Test
  void semantics() {
    String[][] cases = {
      // "abcd".replace(/ab|abc/g, "X"): the first alternative that matches wins, not the longest.
      {"ab|abc", "g", "abcd", "X", "Xcd"},
      // "aaab".replace(/a{1,3}ab/, "X"): greedy, then walked back.
      {"a{1,3}ab", "", "aaab", "X", "X"},
      {"a{2}", "g", "xaaa", "[$&]", "x[aa]a"},
      {"\\d", "g", "a1b2", "#", "a#b#"},
      {"\\d", "", "a1b2", "#", "a#b2"},
      // \b is between ASCII word characters and anything else.
      {"\\bab", "g", "ab xab -ab éab", "X", "X xab -X éX"},
      {"\\Bab", "g", "ab xab", "X", "ab xX"},
      // "maxtokens=1 mytoken=2".replace(/\w+(?<!tokens)=\d/g, "X")
      {"\\w+(?<!tokens)=\\d", "g", "maxtokens=1 mytoken=2", "X", "maxtokens=1 X"},
      {"a(?!b)", "g", "ab ac a", "X", "ab Xc X"},
      {"a(?=b)", "g", "ab ac", "X", "Xb ac"},
      // Groups that did not take part are "" in a template.
      {"(a)|(b)", "g", "ab", "[$1|$2]", "[a|][|b]"},
      {"passw(?:or)?d", "g", "passwd password passwod", "X", "X X passwod"},
      {"(?:ab ){0,3}c", "g", "ab ab ab ab c", "X", "ab X"},
      // /i folds as Canonicalize: the long s (U+017F) and the Kelvin sign stay themselves.
      {"secret|key", "gi", "SECRET Key ſecret Key", "X", "X X ſecret Key"},
      {"[a-z]+", "gi", "AbCÉ", "X", "XÉ"},
      // ...but letters outside ASCII fold too: "ÉtÉ".replace(/é/gi, "e").
      {"é", "gi", "Été", "e", "ete"},
      {"[à-ÿ]+", "gi", "ÀÉx", "X", "Xx"},
      {"[^é]", "gi", "Éa", "X", "ÉX"},
      // \s is JavaScript's set: no-break space, ideographic space, line separator, BOM.
      {"a\\sb", "g", "a b a　b a b a﻿b a\u0085b", "X", "X X X X a\u0085b"},
      // A negated class counts an emoji as two code units.
      {"x[^\\s]{3}", "g", "x😀😀", "X", "X\ude00"},
      {"x[^\\s]{1,4}", "g", "xab😀😀", "X", "X😀"},
      // Escaped punctuation, and "-" at the edge of a class.
      {"a\\/b\\.c[+/=-]", "g", "a/b.c- a/b.c=", "X", "X X"},
      // An empty match moves on one unit.
      {"x*", "g", "ab", "-", "-a-b-"},
      // "{" that is not a quantifier is a literal (Annex B).
      {"a{b", "g", "a{b", "X", "X"},
      {"a", "g", "a", "$$", "$"},
      // $` and $' are what come before and after the match; $0 is literal.
      {"b", "", "abc", "[$`|$'|$0]", "a[a|c|$0]c"},
      // Hex and four-digit escapes; an x escape without hex digits is the letter.
      {"\\x41\\u0042\\xz", "g", "ABxz", "X", "X"},
      // Anchors.
      {"^a|a$", "g", "aba", "X", "XbX"},
    };
    for (String[] c : cases) {
      assertEquals(
          c[4],
          replace(c[0], c[1], c[2], c[3]),
          c[2] + ".replace(/" + c[0] + "/" + c[1] + ", " + c[3] + ")");
    }
  }

  @Test
  void replaceWithAFunction() {
    Regexp re = Regexp.compile("(k)=(?:(\")[^\"]*\"|(')[^']*'|\\w+)", "g");
    String got =
        re.replace(
            "k=\"a b\" k='c' k=d",
            m -> {
              String q = m.group(2) != null ? m.text(2) : m.text(3);
              return m.text(1) + "=" + q + "_" + q;
            });
    assertEquals("k=\"_\" k='_' k=_", got);
  }

  @Test
  void longBoundedRuns() {
    // A {0,16384} run is an ordinary bound, and a run of it does not grow the stack a frame per
    // character.
    Regexp re = Regexp.compile("<(?:[a-z]|-(?!--)){0,16384}>?", "g");
    assertEquals("X", re.replace("<" + "ab-".repeat(5000) + ">", "X"));
    assertEquals("X---", re.replace("<ab---", "X"));
    // 4096, then the rest, then the empty match at the end.
    assertEquals("XXX", Regexp.compile("a{0,4096}", "g").replace("a".repeat(5000), "X"));
  }

  @Test
  void compileErrors() {
    for (String source :
        List.of(
            "(a",
            "a)",
            "*a",
            "[a",
            "a{3,1}",
            "a+?",
            "(?<!a+)b",
            "(?<=a)*b",
            "[z-a]",
            "(?<name>a)",
            // JavaScript reads these as something other than the letter.
            "(a)\\1",
            "\\cJ",
            "\\k<x>",
            "\\p{L}",
            "\\u{41}",
            "[\\2]",
            "\\01")) {
      assertThrows(
          IllegalArgumentException.class, () -> Regexp.compile(source, "g"), "/" + source + "/");
    }
    assertThrows(IllegalArgumentException.class, () -> Regexp.compile("a", "y"));
  }

  @Test
  void matchesAndWritesItself() {
    Regexp re = Regexp.compile("b+", "gi");
    assertEquals(true, re.tryTest("aBc"));
    assertEquals(false, re.tryTest("ac"));
    assertTrue(re.test("abc"));
    assertFalse(re.test("ac"));
    assertEquals("/b+/gi", re.toString());
  }

  @Test
  void aCharacterOutsideTheBmpIsItsTwoUnitsInTurn() {
    // /a😀b/.test("a😀b"), and "x😀😀y".replace(/😀{2}/g, "-"): the quantifier takes the second
    // unit alone, as V8 reads a pattern without u.
    String grin = "😀";
    assertEquals(true, Regexp.compile("a" + grin + "b", "").tryTest("a" + grin + "b"));
    assertEquals(false, Regexp.compile("a" + grin + "b", "").tryTest("ab"));
    assertEquals("x--y", replace(grin + "+", "g", "x" + grin + grin + "y", "-"));
    assertEquals("x" + grin + grin + "y", replace(grin + "{2}", "g", "x" + grin + grin + "y", "-"));
    // /[😀-😁]/ is a SyntaxError in V8: the range runs from \ude00 to \ud83d, out of order.
    assertThrows(IllegalArgumentException.class, () -> Regexp.compile("[" + grin + "-😁]", ""));
    // /[😀]/ holds its two units, each on its own: "😀".replace(/[😀]/g, "-") is "--".
    assertEquals("--", replace("[" + grin + "]", "g", grin, "-"));
  }

  @Test
  void patternsTooDeepOrLongAreRefused() {
    String nested = "(".repeat(2000) + "a" + ")".repeat(2000);
    assertTrue(
        assertThrows(IllegalArgumentException.class, () -> Regexp.compile(nested, ""))
            .getMessage()
            .contains("nested too deeply"));
    Regexp.compile("(".repeat(100) + "a" + ")".repeat(100), "");
    assertTrue(
        assertThrows(IllegalArgumentException.class, () -> Regexp.compile("a".repeat(5000), ""))
            .getMessage()
            .contains("more than 4096 characters"));
    Regexp.compile("a".repeat(4096), "");
  }

  /** The answers a deep match gives: it gives up rather than overflow the thread's stack. */
  private static List<Boolean> deepAnswers() {
    Regexp re = Regexp.compile("(?:ab)*c", "");
    Regexp counted = Regexp.compile("(?:xy){100000}", "");
    List<Boolean> out = new ArrayList<>();
    out.add(re.tryTest("ab".repeat(16_384) + "c"));
    out.add(re.tryTest("ab".repeat(100) + "c"));
    out.add(counted.tryTest("xy".repeat(100_000)));
    return out;
  }

  @Test
  void deepMatchesGiveUpOnAPlatformThreadWithHalfTheDefaultStack() throws InterruptedException {
    // The JVM's default stack is 1 MiB on Linux and more elsewhere; the match fits in half that,
    // run interpreted as it is the first time.
    AtomicReference<Object> result = new AtomicReference<>();
    Thread t = new Thread(null, () -> result.set(run()), "small-stack", 512 * 1024);
    t.start();
    t.join();
    assertDeepAnswers(result.get());
  }

  @Test
  void deepMatchesGiveUpOnAVirtualThread() throws InterruptedException {
    AtomicReference<Object> result = new AtomicReference<>();
    Thread.ofVirtual().start(() -> result.set(run())).join();
    assertDeepAnswers(result.get());
  }

  private static Object run() {
    try {
      return deepAnswers();
    } catch (StackOverflowError e) {
      return e;
    }
  }

  private static void assertDeepAnswers(Object result) {
    assertTrue(result instanceof List<?>, "no stack overflow: " + result);
    List<?> answers = (List<?>) result;
    assertNull(answers.get(0));
    assertEquals(true, answers.get(1));
    assertNull(answers.get(2));
  }

  @Test
  void aMatchThatBacktracksWithoutEndGivesUpWithinItsSteps() {
    // `\n*\n*\n*\n*\n*x` over newlines is some n^5 / 120 attempts; V8 takes seconds over 100. Past
    // the budget the match gives up, while a pattern with work to do answers in full.
    String newlines = "\n".repeat(32_000);
    long started = System.nanoTime();
    assertNull(Regexp.compile("\\n*\\n*\\n*\\n*\\n*x", "").tryTest(newlines));
    assertNull(Regexp.compile(".*x", "").tryTest("a".repeat(32_000)));
    // The budget is counted in steps, not time; the limit only catches a match that never stops.
    assertTrue(System.nanoTime() - started < 60_000_000_000L, "gave up within a minute");
    assertEquals(false, Regexp.compile("\\n*\\n*\\n*\\n*\\n*x", "").tryTest("\n".repeat(20)));
    assertEquals(true, Regexp.compile("\\n*\\n*\\n*\\n*\\n*x", "").tryTest(newlines + "x"));
    assertEquals(true, Regexp.compile(".*done", "").tryTest("a".repeat(32_000) + "done"));
    // Redaction has no budget: its patterns are the SDK's own, bounded.
    String as = "a".repeat(4_000);
    assertEquals(as, Regexp.compile(".*x", "g").replace(as, ""));
    assertNull(Regexp.compile(".*x", "g").tryReplace("a".repeat(32_000), ""));
  }
}
