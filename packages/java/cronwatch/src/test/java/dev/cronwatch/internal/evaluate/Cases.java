package dev.cronwatch.internal.evaluate;

import dev.cronwatch.AlertDetails;
import dev.cronwatch.AlertType;
import dev.cronwatch.Definition;
import dev.cronwatch.Fixtures;
import dev.cronwatch.Run;
import dev.cronwatch.internal.evaluate.Evaluate.AlertDraft;
import dev.cronwatch.internal.jsre.Regexp;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import org.jspecify.annotations.Nullable;

/** What the evaluate, format, and health replays share: reading their fixtures' values. */
final class Cases {
  private Cases() {}

  /** A definition from a fixture's object. */
  static Definition definition(@Nullable Object v) {
    return Definition.of(v instanceof JsObject o ? o : new JsObject());
  }

  /** A run from a fixture, or null. */
  static @Nullable Run run(@Nullable Object v) {
    return v == null ? null : Run.fromValue(v);
  }

  /** An alert draft from a fixture, {@code {type, run, details}}. */
  static AlertDraft draft(Object v) {
    JsObject o = (JsObject) v;
    AlertType type = AlertType.of(Fixtures.string(o, "type"));
    return new AlertDraft(
        type, run(o.get("run")), AlertDetails.fromValue(type, Fixtures.object(o, "details")));
  }

  /**
   * An expect rule from a fixture: a string, a JavaScript RegExp as {@code {regex: {source,
   * flags}}}, or a function as {@code {callable: true}}, which the script makes as {@code (o) =>
   * o.length > 3}.
   */
  static Expect rule(@Nullable Object v) {
    if (v instanceof String s) {
      return new Expect.Contains(s);
    }
    if (v instanceof JsObject o && o.get("regex") instanceof JsObject re) {
      return new Expect.Matches(
          Regexp.compile(Fixtures.string(re, "source"), Fixtures.string(re, "flags")));
    }
    if (v instanceof JsObject) {
      return new Expect.That(out -> out.length() > 3);
    }
    throw new IllegalArgumentException("not an expect rule: " + Json.stringify(v));
  }
}
