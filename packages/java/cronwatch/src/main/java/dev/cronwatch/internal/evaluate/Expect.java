package dev.cronwatch.internal.evaluate;

import dev.cronwatch.Definition;
import dev.cronwatch.internal.jsre.Regexp;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.Map;
import java.util.Objects;
import java.util.function.Predicate;
import org.jspecify.annotations.Nullable;

/**
 * A job's expect rule: what a successful run's output must satisfy, and how the rule is described
 * in the stored definition (the SDK's {@code serialize.ts}).
 */
public sealed interface Expect permits Expect.Contains, Expect.Matches, Expect.That {
  /** Null when the output passes, or why it does not. */
  @Nullable String check(String output);

  /** The stored definition's {@code expect}. */
  String describe();

  /** The output must contain the text. */
  record Contains(String text) implements Expect {
    /** Checks that the text is there. */
    public Contains {
      Objects.requireNonNull(text, "text");
    }

    @Override
    public @Nullable String check(String output) {
      return output.contains(text) ? null : "Output did not contain " + Json.quote(text);
    }

    @Override
    public String describe() {
      return "contains " + Json.quote(text);
    }
  }

  /**
   * A JavaScript pattern must match somewhere in the output, run by the port's own engine. A match
   * that gives up (past its step budget or its frames) does not match, so the run fails: a pattern
   * is slow because it is searching an output it does not match.
   */
  record Matches(Regexp pattern) implements Expect {
    /** Checks that the pattern is there. */
    public Matches {
      Objects.requireNonNull(pattern, "pattern");
    }

    @Override
    public @Nullable String check(String output) {
      Boolean matched = pattern.tryTest(output);
      return Boolean.TRUE.equals(matched) ? null : "Output did not match " + pattern;
    }

    @Override
    public String describe() {
      return "matches " + pattern;
    }
  }

  /** A predicate of the app's must answer true for the output. */
  record That(Predicate<String> predicate) implements Expect {
    /** Checks that the predicate is there. */
    public That {
      Objects.requireNonNull(predicate, "predicate");
    }

    @Override
    public @Nullable String check(String output) {
      try {
        return predicate.test(output) ? null : "Output did not pass the expect() check";
      } catch (Exception e) {
        // Like the SDK's (error as Error).message: a throw with no message has an empty one.
        return "Output check threw: " + Objects.toString(e.getMessage(), "");
      }
    }

    @Override
    public String describe() {
      return "custom function";
    }
  }

  /**
   * {@code checkExpectation}: null when there is no rule or the output satisfies it, else why not.
   */
  static @Nullable String checkExpectation(@Nullable Expect rule, @Nullable String output) {
    return rule == null ? null : rule.check(output == null ? "" : output);
  }

  /**
   * A definition as a store can hold it ({@code toStored}): the fields as given, less {@code
   * expect}, which goes last as a description.
   */
  static Definition toStored(JsObject fields, @Nullable Expect rule) {
    JsObject out = new JsObject();
    for (Map.Entry<String, @Nullable Object> e : fields.entries()) {
      if (!e.getKey().equals("expect")) {
        out.set(e.getKey(), Json.copy(e.getValue()));
      }
    }
    if (rule != null) {
      out.set("expect", rule.describe());
    }
    return Definition.of(out);
  }
}
