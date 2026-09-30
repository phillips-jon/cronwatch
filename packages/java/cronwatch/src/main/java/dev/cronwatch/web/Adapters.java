package dev.cronwatch.web;

import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.web.Requests;
import dev.cronwatch.internal.web.Text;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/**
 * What an adapter needs to hand a framework's request to {@link Routes#handle} or {@link
 * Handler#handle} as the SDK reads a fetch {@code Request}: the servlet adapter and the Spring Boot
 * starter use it, and so can an adapter for a framework this library has none for.
 */
public final class Adapters {
  private Adapters() {}

  /**
   * The request target as sent, from the text a server read: the JDK's server and the servlet
   * containers read the request line a byte a character, so a target sent as UTF-8 is read back as
   * UTF-8 (and one that is not is left as it is).
   */
  public static String target(String rawPath, @Nullable String rawQuery) {
    return Text.utf8OrAsIs(rawQuery == null ? rawPath : rawPath + "?" + rawQuery);
  }

  /**
   * A form body written back from a container's parsed parameters, for a body a filter ahead of the
   * dashboard already read: every parameter but those of the query, which the servlet specification
   * puts first for each name, written as {@code URLSearchParams} writes a form.
   */
  public static byte[] formBody(Map<String, String[]> parameters, @Nullable String rawQuery) {
    Map<String, Integer> inQuery = new HashMap<>();
    if (rawQuery != null) {
      for (Map.Entry<String, String> p : Requests.parseQuery(rawQuery)) {
        inQuery.merge(p.getKey(), 1, Integer::sum);
      }
    }
    List<String> pairs = new ArrayList<>();
    for (Map.Entry<String, String[]> e : parameters.entrySet()) {
      String[] values = e.getValue();
      for (int i = inQuery.getOrDefault(e.getKey(), 0); i < values.length; i++) {
        pairs.add(Requests.formEncode(e.getKey()) + "=" + Requests.formEncode(values[i]));
      }
    }
    return Js.utf8(String.join("&", pairs));
  }
}
