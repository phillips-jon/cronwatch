package dev.cronwatch.internal.output;

import dev.cronwatch.internal.jsre.Regexp;
import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Function;
import java.util.function.UnaryOperator;
import org.jspecify.annotations.Nullable;

/**
 * The SDK's {@code output.ts}: the output cap, error text, and secret redaction. Lengths and cuts
 * are in UTF-16 code units, as JavaScript counts them (a Java string is one), so the same output is
 * capped at the same character here and in every other port.
 */
public final class Output {
  private Output() {}

  /** How much output a run keeps: 16 KB of UTF-16 code units, the tail. */
  public static final int OUTPUT_CAP = 16 * 1024;

  /** What replaces a secret. */
  public static final String REDACTED = "[redacted]";

  /**
   * Removes every U+0000. Postgres refuses NUL in TEXT and JSONB, and the whole run row would be
   * lost with it.
   */
  public static String stripNul(String text) {
    return text.indexOf('\0') < 0 ? text : text.replace("\0", "");
  }

  /** {@link #stripNul} for a text that may be null. */
  public static @Nullable String stripNulOrNull(@Nullable String text) {
    return text == null ? null : stripNul(text);
  }

  /**
   * Removes every U+0000 from JSON text, keys and strings alike, by dropping each {@code \u0000}
   * escape (a NUL can appear in JSON no other way). Escapes are read left to right in pairs, so an
   * escaped backslash followed by {@code u0000} is left as it is.
   */
  public static String stripJsonNul(String json) {
    if (!json.contains("\\u0000")) {
      return json;
    }
    StringBuilder out = new StringBuilder(json.length());
    int i = 0;
    while (i < json.length()) {
      char c = json.charAt(i);
      if (c != '\\' || i + 1 >= json.length()) {
        out.append(c);
        i++;
      } else if (json.startsWith("u0000", i + 1)) {
        i += 6;
      } else {
        out.append(c).append(json.charAt(i + 1));
        i += 2;
      }
    }
    return out.toString();
  }

  private static final String TRIMMED = "[earlier output trimmed]\n";

  /**
   * How much text before the kept tail redaction reads, and never keeps: three times the longest
   * secret a default pattern can match (a PEM key's 16 KB body with its header and footer, under
   * {@code OUTPUT_CAP + 1024}), since a replacement grows what it replaces at most threefold.
   */
  public static final int REDACT_EDGE = 3 * (OUTPUT_CAP + 1024);

  /**
   * Removes NULs, then keeps the last {@link #OUTPUT_CAP} code units behind a line saying the rest
   * was trimmed. A cut through a surrogate pair keeps the lone half, as JavaScript does; it becomes
   * U+FFFD once written out as UTF-8.
   */
  public static String cap(String text) {
    String clean = stripNul(text);
    if (clean.length() <= OUTPUT_CAP) {
      return clean;
    }
    return TRIMMED + clean.substring(clean.length() - OUTPUT_CAP);
  }

  /**
   * Output or an error as it is stored: redacted, then capped like {@link #cap}, so the cut cannot
   * fall inside a secret and keep what follows its label. Text of at most {@code OUTPUT_CAP +
   * REDACT_EDGE} units is redacted whole. Longer text is cut to that many units from its end first,
   * and after redacting, the first {@link #REDACT_EDGE} units are never kept: a secret whose label
   * fell before that cut is left out with them. NULs go before and after {@code redact}.
   */
  public static String redactAndCap(String text, UnaryOperator<String> redact) {
    String clean = stripNul(text);
    int from = clean.length() - (OUTPUT_CAP + REDACT_EDGE);
    if (from <= 0) {
      return cap(redact.apply(clean));
    }
    String redacted = stripNul(redact.apply(clean.substring(from)));
    return TRIMMED
        + redacted.substring(
            Math.min(redacted.length(), Math.max(redacted.length() - OUTPUT_CAP, REDACT_EDGE)));
  }

  /** {@link #redactAndCap} for a text that may be null. */
  public static @Nullable String redactAndCapOrNull(
      @Nullable String text, UnaryOperator<String> redact) {
    return text == null ? null : redactAndCap(text, redact);
  }

  /**
   * An error as a JavaScript stack reads, capped like output: {@code Name: message}, then up to
   * five frames, each {@code " at <frame>"}.
   */
  public static String errorMessage(String name, String message, List<String> frames) {
    return cap(describeError(name, message, frames));
  }

  /** {@link #errorMessage(String, String, List)} not capped: see {@link #redactAndCap}. */
  public static String describeError(String name, String message, List<String> frames) {
    StringBuilder b = new StringBuilder(name).append(": ").append(message);
    for (int k = 0; k < Math.min(5, frames.size()); k++) {
      b.append("\n    at ").append(frames.get(k));
    }
    return b.toString();
  }

  /**
   * A throwable as the SDK writes an error: its name (the class's simple name, as JavaScript's
   * {@code error.name} is short, or the binary name for an anonymous class, whose simple name is
   * empty), its message ({@code getMessage()}, empty when null, as {@code new Error()} has an empty
   * one), and up to five frames, innermost first, each {@code com.example.Reports.build
   * (Reports.java:42)}. Causes are not written, as the SDK writes only the error's own stack.
   */
  public static String errorMessage(Throwable error) {
    return cap(describeError(error));
  }

  /** {@link #errorMessage(Throwable)} not capped: see {@link #redactAndCap}. */
  public static String describeError(Throwable error) {
    Class<?> type = error.getClass();
    String name = type.getSimpleName().isEmpty() ? type.getName() : type.getSimpleName();
    String message = error.getMessage();
    StackTraceElement[] trace = error.getStackTrace();
    List<String> frames = new ArrayList<>(Math.min(5, trace.length));
    for (int k = 0; k < Math.min(5, trace.length); k++) {
      frames.add(frame(trace[k]));
    }
    return describeError(name, message == null ? "" : message, frames);
  }

  /**
   * What the SDK writes for anything thrown: a throwable as {@link #errorMessage(Throwable)}, a
   * string as it is, anything else as its JSON (or its {@code toString} when it has none), capped
   * like output.
   */
  public static String errorMessage(@Nullable Object error) {
    return cap(describeError(error));
  }

  /** {@link #errorMessage(Object)} not capped: see {@link #redactAndCap}. */
  public static String describeError(@Nullable Object error) {
    if (error instanceof Throwable t) {
      return describeError(t);
    }
    if (error instanceof String s) {
      return s;
    }
    try {
      return Json.stringify(error);
    } catch (IllegalArgumentException e) {
      return String.valueOf(error);
    }
  }

  /** A frame as a JavaScript stack writes one: the class and method, then where, in parentheses. */
  static String frame(StackTraceElement e) {
    String where;
    if (e.isNativeMethod()) {
      where = "Native Method";
    } else if (e.getFileName() == null) {
      where = "Unknown Source";
    } else if (e.getLineNumber() >= 0) {
      where = e.getFileName() + ":" + e.getLineNumber();
    } else {
      where = e.getFileName();
    }
    return e.getClassName() + "." + e.getMethodName() + " (" + where + ")";
  }

  /** One of the SDK's secret patterns and what replaces a match. */
  private record Pattern(Regexp re, Function<Regexp.Match, String> replace) {
    static Pattern template(String source, String flags, String replacement) {
      Regexp re = Regexp.compile(source, flags);
      // Only $1 is named in the SDK's replacements.
      return new Pattern(re, m -> replacement.replace("$1", m.text(1)));
    }
  }

  /**
   * The SDK's patterns ({@code packages/sdk/src/output.ts}, {@code SECRET_PATTERNS}), as JavaScript
   * source, character for character. Bounded quantifiers throughout, so a long line cannot make
   * these backtrack. They apply in this order, each to the text the ones before it left.
   */
  private static final List<Pattern> PATTERNS =
      List.of(
          // A PEM private key, header to footer. Without a footer (the output was trimmed) it runs
          // to the end of the base64 body. A "-" that starts five dashes ends the body, so the
          // footer is never swallowed into it.
          Pattern.template(
              "-----BEGIN (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----(?:[A-Za-z0-9+/=\\s,:]|-(?!----)){0,16384}(?:-----END (?:[A-Z0-9]{1,20} ){0,3}PRIVATE KEY-----)?",
              "g",
              REDACTED),
          // password=..., API_KEY: ..., "client_secret": "...", TOKEN='...', token=...,
          // :password=>"..." (but not max_tokens: 800). A quoted value is blanked to its closing
          // quote, spaces and all, and keeps its quotes.
          new Pattern(
              Regexp.compile(
                  "\\b([A-Za-z0-9_-]{0,40}(?:secret|token|passw(?:or)?d|pwd|api[_-]?key|access[_-]?key|private[_-]?key|credential)[A-Za-z0-9_-]{0,40}(?<![Tt][Oo][Kk][Ee][Nn][Ss])\"?\\s{0,3}(?:=>|[=:])\\s{0,3})(?:(\")[^\"\\n]{1,4096}\"|(')[^'\\n]{1,4096}'|[\"']?[^\\s\"',;&]{1,4096})",
                  "gi"),
              m -> {
                String quote = m.group(2) != null ? m.text(2) : m.text(3);
                return m.text(1) + quote + REDACTED + quote;
              }),
          // Authorization: Basic <base64> and Authorization: Token <token>, also as a JSON or hash
          // entry.
          Pattern.template(
              "\\b((?:proxy-)?authorization[\"']?\\s{0,3}(?:=>|[=:])\\s{0,3}[\"']?\\s{0,3}(?:basic|token)\\s{1,3})[A-Za-z0-9._~+/=:-]{1,4096}",
              "gi",
              "$1" + REDACTED),
          // Credentials inside a URL: postgres://user:password@host. The password runs to the last
          // "@" before a "/" or a space, so one that contains "@" is blanked whole.
          Pattern.template(
              "(\\b[a-z][a-z0-9+.-]{0,30}:\\/\\/[^\\s/:@]{0,256}:)[^\\s/]{1,256}@",
              "gi",
              "$1" + REDACTED + "@"),
          // Authorization: Bearer <token>
          Pattern.template("\\b(Bearer\\s{1,3})[A-Za-z0-9._~+/=-]{8,4096}", "g", "$1" + REDACTED),
          // A bare JWT: three base64url segments, the first starting eyJ.
          Pattern.template(
              "\\beyJ[A-Za-z0-9_-]{4,4096}\\.[A-Za-z0-9_-]{4,4096}\\.[A-Za-z0-9_-]{0,4096}",
              "g",
              REDACTED),
          // Incoming webhook URLs carry their secret in the path.
          Pattern.template(
              "(\\bhooks\\.slack\\.com\\/(?:services|workflows|triggers)\\/)[A-Za-z0-9/_-]{1,255}",
              "gi",
              "$1" + REDACTED),
          Pattern.template(
              "(\\bdiscord(?:app)?\\.com\\/api\\/(?:v\\d{1,2}\\/)?webhooks\\/)[A-Za-z0-9/_-]{1,255}",
              "gi",
              "$1" + REDACTED),
          // Well-known token shapes: AWS, GitHub, Slack, Stripe, Anthropic, OpenAI, and Google
          // style keys.
          Pattern.template("\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b", "g", REDACTED),
          Pattern.template(
              "\\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{20,255})\\b",
              "g",
              REDACTED),
          Pattern.template("\\bxox[abposr]-[A-Za-z0-9-]{10,255}", "g", REDACTED),
          Pattern.template("\\b[rsp]k_(?:live|test)_[A-Za-z0-9]{10,255}\\b", "g", REDACTED),
          Pattern.template("\\bwhsec_[A-Za-z0-9+/=]{16,255}", "g", REDACTED),
          Pattern.template("\\bsk-[A-Za-z0-9_-]{20,255}", "g", REDACTED),
          Pattern.template("\\bAIza[0-9A-Za-z_-]{35}(?![0-9A-Za-z_-])", "g", REDACTED));

  /**
   * The default redact: blanks values that look like secrets (key=value pairs with secret-ish
   * names, Authorization headers, URL credentials, bearer tokens, JWTs, PEM private keys, webhook
   * URLs, and well-known token formats) before output or an error is stored, shown, or sent
   * anywhere.
   */
  public static String redactSecrets(String text) {
    String out = text;
    for (Pattern p : PATTERNS) {
      out = p.re().replace(out, p.replace());
    }
    return out;
  }
}
