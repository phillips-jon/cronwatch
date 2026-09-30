package dev.cronwatch;

import dev.cronwatch.internal.core.Friends;
import dev.cronwatch.internal.evaluate.Expect;
import dev.cronwatch.internal.jsre.Regexp;
import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.List;

/** The client's side of {@link Friends}, for the bridge. */
final class Friend implements Friends.Client {
  @Override
  public Definition describe(Cronwatch cw, String name, JobOptions options) {
    return cw.define(name, options).stored();
  }

  @Override
  public void ensureReady(Cronwatch cw) {
    cw.core.ensureReady();
  }

  @Override
  public JobOptions withStoredExpect(JobOptions options, String description) {
    if (description.startsWith("contains ")) {
      options.expect = contains(description);
    } else if (description.startsWith("matches ")) {
      options.expect = matches(description);
    } else if (description.equals("custom function")) {
      options.expect = new Expect.That(output -> true);
    } else {
      options.expect = new Expect.Stored(description);
    }
    return options;
  }

  @Override
  public List<String> tags(JobOptions options) {
    List<String> out = new ArrayList<>();
    if (options.fields.get("tags") instanceof List<?> tags) {
      for (Object t : tags) {
        if (t instanceof String s) {
          out.add(s);
        }
      }
    }
    return out;
  }

  /** A stored {@code contains "text"}, or the description kept when it is not JSON text. */
  private static Expect contains(String description) {
    try {
      if (Json.parse(description.substring("contains ".length())) instanceof String want) {
        return new Expect.Contains(want);
      }
    } catch (Json.JsonException e) {
      // Kept as stored, below.
    }
    return new Expect.Stored(description);
  }

  /**
   * A stored {@code matches /source/flags}: run by the engine when it reads the pattern, and
   * passing every output with its description kept when it cannot.
   */
  private static Expect matches(String description) {
    String pattern = description.substring("matches ".length());
    int end = pattern.lastIndexOf('/');
    if (pattern.startsWith("/") && end > 0) {
      try {
        Regexp r = Regexp.compile(pattern.substring(1, end), pattern.substring(end + 1));
        if (("matches " + r).equals(description)) {
          return new Expect.Matches(r);
        }
      } catch (IllegalArgumentException e) {
        // Kept as stored, below.
      }
    }
    return new Expect.Stored(description);
  }
}
