package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.post.Post;
import dev.cronwatch.json.JsObject;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.function.Function;
import org.jspecify.annotations.Nullable;

/**
 * What every email channel sends ({@code alerts/email.ts}): one subject, a plain text body, and a
 * small HTML body, so an alert reads the same whichever provider carries it.
 */
final class Email {
  private Email() {}

  /**
   * The options every email channel shares, checked.
   *
   * @param from the sender
   * @param to the recipients, trimmed, none blank
   * @param subjectPrefix put in front of the title, or {@code ""}
   * @param link a link back to the job, or null
   */
  record Settings(
      String from,
      List<String> to,
      String subjectPrefix,
      @Nullable Function<dev.cronwatch.Alert, @Nullable String> link) {
    @Override
    public String toString() {
      return "Settings[" + to.size() + " recipients]";
    }
  }

  /**
   * One alert as a mail.
   *
   * @param from the sender
   * @param to the recipients
   * @param subject one line
   * @param text the plain text body
   * @param html the HTML body
   */
  record Mail(String from, List<String> to, String subject, String text, String html) {}

  /** The mail for an alert. */
  static Mail compose(Alert a, Settings s) {
    String link = safeLink(Shared.link(s.link(), a));
    String prefix = s.subjectPrefix().isEmpty() ? "" : s.subjectPrefix() + " ";
    // One line: a newline in a subject is a header injection or a rejected send.
    String subject = Post.cut(oneLine(prefix + a.title()), 250);
    return new Mail(s.from(), s.to(), subject, Shared.plainText(a, link), html(a, link));
  }

  /** {@code .replace(/[\r\n]+/g, " ")}. */
  static String oneLine(String text) {
    StringBuilder b = new StringBuilder(text.length());
    boolean breaking = false;
    for (int i = 0; i < text.length(); i++) {
      char c = text.charAt(i);
      if (c == '\r' || c == '\n') {
        if (!breaking) {
          b.append(' ');
        }
        breaking = true;
      } else {
        b.append(c);
        breaking = false;
      }
    }
    return b.toString();
  }

  /** Escapes text for HTML content and double quoted attributes. */
  static String escapeHtml(String text) {
    return text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&#39;");
  }

  /** Only http and https links are put in a mail; anything else is dropped. */
  static String safeLink(String link) {
    String lower = link.substring(0, Math.min(8, link.length())).toLowerCase(Locale.ROOT);
    return lower.startsWith("http://") || lower.startsWith("https://") ? link : "";
  }

  private static String html(Alert a, String link) {
    List<String> parts = new ArrayList<>();
    parts.add("<!doctype html>");
    parts.add(
        "<html><body style=\"margin:0;padding:16px;font-family:Georgia,serif;color:#1d1b16;background:#ffffff\">");
    parts.add(
        "<p style=\"margin:0 0 12px;font-size:18px\"><strong>"
            + escapeHtml(a.title())
            + "</strong></p>");
    parts.add(
        "<pre style=\"margin:0 0 12px;padding:12px;background:#f6f3ec;white-space:pre-wrap;word-break:break-word;font:13px/1.45 Menlo,Consolas,monospace\">"
            + escapeHtml(a.message())
            + "</pre>");
    if (!Shared.triage(a).isEmpty()) {
      parts.add(
          "<p style=\"margin:0 0 12px\"><em>Triage:</em> " + escapeHtml(Shared.triage(a)) + "</p>");
    }
    if (!link.isEmpty()) {
      parts.add(
          "<p style=\"margin:0\"><a href=\""
              + escapeHtml(link)
              + "\">Open "
              + escapeHtml(a.job())
              + "</a></p>");
    }
    parts.add("</body></html>");
    return String.join("\n", parts);
  }

  /**
   * {@code Name <a@b.c>} split into its parts; a bare address has no name (email.ts's {@code
   * parseAddress}: {@code /^\s*(.*?)\s*<([^<>]+)>\s*$/}, then the name without the double quotes
   * around it).
   */
  static JsObject parseAddress(String text) {
    JsObject bare = new JsObject().set("email", Js.trim(text));
    String s = Js.trimEnd(text);
    if (!s.endsWith(">")) {
      return bare;
    }
    String inner = s.substring(0, s.length() - 1);
    int at = inner.lastIndexOf('<');
    if (at < 0) {
      return bare;
    }
    String address = inner.substring(at + 1);
    if (address.isEmpty() || address.indexOf('>') >= 0) {
      return bare;
    }
    String name = Js.trim(inner.substring(0, at));
    // JavaScript's . matches no line terminator.
    for (int i = 0; i < name.length(); i++) {
      char c = name.charAt(i);
      if (c == '\n' || c == '\r' || c == ' ' || c == ' ') {
        return bare;
      }
    }
    if (name.length() >= 2 && name.startsWith("\"") && name.endsWith("\"")) {
      name = name.substring(1, name.length() - 1);
    }
    JsObject o = new JsObject().set("email", Js.trim(address));
    if (!name.isEmpty()) {
      o.set("name", name);
    }
    return o;
  }
}
