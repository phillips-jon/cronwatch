package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.AlertType;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.post.Post;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

/**
 * Texts alerts through Twilio ({@code alerts/twilio.ts}), to every number at once, a virtual thread
 * each: {@code POST https://api.twilio.com/2010-04-01/Accounts/<AccountSid>/Messages.json}, form
 * encoded, with basic auth. The alert counts as delivered when any number took it; each number that
 * refused it is reported to the client's error handler. It fails only when every number did.
 */
public final class Twilio implements Channel {
  /** The most segments a text may use, which keeps it inside Twilio's 1600 character limit. */
  private static final int MAX_SEGMENTS = 10;

  /** The longest Body Twilio takes. */
  static final int MAX_BODY = 1600;

  // The GSM 03.38 alphabet: a message in it takes 153 characters a segment (when split),
  // anything else is UCS-2 at 67. The extension table costs two.
  private static final String GSM =
      "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà";
  private static final String GSM_EXTENDED = "^{}\\[~]|€\f";

  private final TwilioOptions options;
  private final String url;
  private final String authorization;

  private Twilio(TwilioOptions options) {
    this.options = Objects.requireNonNull(options, "options");
    this.url =
        "https://api.twilio.com/2010-04-01/Accounts/"
            + Shared.encodeUriComponent(options.accountSid)
            + "/Messages.json";
    this.authorization = Shared.basicAuth(options.user, options.password);
  }

  /** The channel. */
  public static Twilio channel(TwilioOptions options) {
    return new Twilio(options);
  }

  @Override
  public String name() {
    return "twilio";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    if (alert.type().equals(AlertType.RECOVERED) && !options.recovered) {
      return;
    }
    String body = smsBody(alert, Shared.link(options.link, alert), options.segments);
    Transport transport = Shared.transport(options.transport, context);
    List<String> to = options.to;
    List<String> errors = new ArrayList<>();
    try (ExecutorService texts =
        Executors.newThreadPerTaskExecutor(
            Thread.ofVirtual().name("cronwatch-twilio-", 0).factory())) {
      List<Future<?>> sent = new ArrayList<>();
      for (String number : to) {
        List<Map.Entry<String, String>> form = new ArrayList<>();
        form.add(Map.entry("To", number));
        if (!options.messagingServiceSid.isEmpty()) {
          form.add(Map.entry("MessagingServiceSid", options.messagingServiceSid));
        } else {
          form.add(Map.entry("From", options.from));
        }
        form.add(Map.entry("Body", body));
        sent.add(
            texts.submit(
                () -> {
                  Shared.send(
                      transport,
                      "Twilio",
                      url,
                      Shared.headers(
                          "content-type",
                          "application/x-www-form-urlencoded",
                          "authorization",
                          authorization),
                      Shared.form(form),
                      List.of(options.password));
                  return null;
                }));
      }
      for (Future<?> f : sent) {
        try {
          f.get();
          errors.add(null);
        } catch (ExecutionException e) {
          Throwable cause = e.getCause() == null ? e : e.getCause();
          errors.add(message(cause));
        } catch (InterruptedException e) {
          // The channel's time is up: every text still going is abandoned with it.
          texts.shutdownNow();
          throw e;
        }
      }
    }
    List<Integer> failed = new ArrayList<>();
    for (int i = 0; i < errors.size(); i++) {
      if (errors.get(i) != null) {
        failed.add(i);
      }
    }
    if (failed.isEmpty()) {
      return;
    }
    int n = to.size();
    if (failed.size() == n) {
      String message = errors.get(failed.get(0));
      throw Post.fail(
          n > 1 ? message + " (" + failed.size() + " of " + n + " numbers failed)" : message);
    }
    // Delivered to someone: counted as sent, so a retry never texts the numbers that took it again.
    for (int i : failed) {
      context.reportError(
          errors.get(i)
              + " (to "
              + maskNumber(to.get(i))
              + "; "
              + (n - failed.size())
              + " of "
              + n
              + " numbers took the alert)");
    }
  }

  /** An error's message, or its class's name when it has none. */
  private static String message(Throwable e) {
    String m = e.getMessage();
    return m == null ? e.getClass().getSimpleName() : m;
  }

  /** A number with all but its last four digits hidden, for an error message. */
  static String maskNumber(String number) {
    int n = number.length();
    return n <= 4 ? number : "*".repeat(Math.min(n - 4, 8)) + Js.tail(number, 4);
  }

  /**
   * The segments {@code text} takes. A character is never split across two: an extension character
   * (two septets) or a surrogate pair (two UCS-2 units) that would straddle a boundary starts the
   * next segment, as phones pack them.
   */
  static int smsSegments(String text) {
    List<Integer> units = new ArrayList<>();
    boolean gsm = true;
    for (int i = 0; i < text.length(); ) {
      int cp = text.codePointAt(i);
      i += Character.charCount(cp);
      if (GSM.indexOf(cp) >= 0) {
        units.add(1);
      } else if (GSM_EXTENDED.indexOf(cp) >= 0) {
        units.add(2);
      } else {
        gsm = false;
        break;
      }
    }
    int single = 160;
    int per = 153;
    if (!gsm) {
      single = 70;
      per = 67;
      units.clear();
      for (int i = 0; i < text.length(); ) {
        int cp = text.codePointAt(i);
        i += Character.charCount(cp);
        units.add(Character.charCount(cp));
      }
    }
    int total = 0;
    for (int u : units) {
      total += u;
    }
    if (total <= single) {
      return 1;
    }
    int count = 1;
    int used = 0;
    for (int u : units) {
      if (used + u > per) {
        count++;
        used = 0;
      }
      used += u;
    }
    return count;
  }

  /** Whether {@code text} fits within {@code segments} SMS segments and Twilio's Body limit. */
  private static boolean fits(String text, int segments) {
    return text.length() <= MAX_BODY && smsSegments(text) <= segments;
  }

  /** A segment count held to 1 to {@link #MAX_SEGMENTS}; 3 for anything not a number. */
  static int segmentBudget(double segments) {
    if (!Double.isFinite(segments)) {
      return 3;
    }
    return (int) Math.min(MAX_SEGMENTS, Math.max(1, Math.floor(segments)));
  }

  /**
   * The title, then as many lines of the message (and the triage) as fit, then the link. The link
   * is kept whole; the text before it is cut to make room.
   */
  static String smsBody(Alert a, String link, double segments) {
    int budget = segmentBudget(segments);
    String tail = link.isEmpty() ? "" : "\n" + link;
    List<String> lines = new ArrayList<>();
    lines.add(a.title());
    for (String l : a.message().split("\n", -1)) {
      if (!Js.trim(l).isEmpty()) {
        lines.add(l);
      }
    }
    if (!Shared.triage(a).isEmpty()) {
      lines.add("Triage: " + Shared.triage(a));
    }
    String text = "";
    for (String line : lines) {
      String next = text.isEmpty() ? line : text + "\n" + line;
      if (fits(next + tail, budget)) {
        text = next;
        continue;
      }
      // Part of this line, cut on a code point and marked.
      int[] chars = line.codePoints().toArray();
      int lo = 0;
      int hi = chars.length;
      String before = text.isEmpty() ? "" : text + "\n";
      while (lo < hi) {
        int mid = (lo + hi + 1) / 2;
        String candidate = before + new String(chars, 0, mid) + "...";
        if (fits(candidate + tail, budget)) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      if (lo > 0) {
        text = before + new String(chars, 0, lo) + "...";
      }
      break;
    }
    // Only a link too long for any budget gets here too long; Twilio would refuse it whole.
    return Post.cut(text + tail, MAX_BODY);
  }

  @Override
  public String toString() {
    return "Twilio";
  }
}
