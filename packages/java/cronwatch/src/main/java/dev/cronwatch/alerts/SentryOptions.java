package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.internal.post.WhatwgUrl;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.function.Function;
import org.jspecify.annotations.Nullable;

/** Configures {@link Sentry}. */
public final class SentryOptions {
  final String endpoint;
  final String publicKey;
  final String environment;
  final String release;
  final boolean recovered;
  final @Nullable Function<Alert, @Nullable String> link;
  final @Nullable Transport transport;

  private SentryOptions(Builder b, String endpoint, String publicKey) {
    this.endpoint = endpoint;
    this.publicKey = publicKey;
    this.environment = b.environment;
    this.release = b.release;
    this.recovered = b.recovered;
    this.link = b.link;
    this.transport = b.transport;
  }

  /** A builder with nothing set. */
  public static Builder builder() {
    return new Builder();
  }

  /** Names what is set, never the DSN, whose user name is the project's key. */
  @Override
  public String toString() {
    return "SentryOptions[dsn=set, environment=" + environment + ", recovered=" + recovered + "]";
  }

  /**
   * The envelope endpoint and the public key of a DSN, as the SDK's {@code parseDsn} reads them.
   */
  static String[] parseDsn(String dsn) {
    if (!(WhatwgUrl.parse(dsn) instanceof WhatwgUrl.Special s)) {
      throw Shared.invalid("Sentry needs a valid dsn");
    }
    WhatwgUrl url = s.url();
    List<String> segments = new ArrayList<>();
    for (String seg : url.path().split("/", -1)) {
      if (!seg.isEmpty()) {
        segments.add(seg);
      }
    }
    String project = segments.isEmpty() ? "" : segments.remove(segments.size() - 1);
    if (url.username().isEmpty() || !project.matches("[0-9]+")) {
      throw Shared.invalid("Sentry needs a dsn like https://<key>@<host>/<project>");
    }
    String prefix = segments.isEmpty() ? "" : "/" + String.join("/", segments);
    String host = url.port() < 0 ? url.host() : url.host() + ":" + url.port();
    String endpoint = url.scheme() + "://" + host + prefix + "/api/" + project + "/envelope/";
    return new String[] {endpoint, decodeUriComponent(url.username())};
  }

  /** {@code decodeURIComponent}, refusing what it throws on (a malformed escape or UTF-8). */
  private static String decodeUriComponent(String text) {
    byte[] in = text.getBytes(StandardCharsets.UTF_8);
    ByteBuffer out = ByteBuffer.allocate(in.length);
    for (int i = 0; i < in.length; i++) {
      if (in[i] == '%') {
        int h = i + 2 < in.length ? Character.digit(in[i + 1], 16) : -1;
        int l = i + 2 < in.length ? Character.digit(in[i + 2], 16) : -1;
        if (h < 0 || l < 0) {
          throw Shared.invalid("Sentry needs a valid dsn");
        }
        out.put((byte) (h << 4 | l));
        i += 2;
      } else {
        out.put(in[i]);
      }
    }
    out.flip();
    try {
      return StandardCharsets.UTF_8
          .newDecoder()
          .onMalformedInput(CodingErrorAction.REPORT)
          .onUnmappableCharacter(CodingErrorAction.REPORT)
          .decode(out)
          .toString();
    } catch (CharacterCodingException e) {
      throw Shared.invalid("Sentry needs a valid dsn");
    }
  }

  /** Builds {@link SentryOptions}. */
  public static final class Builder extends ChannelBuilder<Builder> {
    private String dsn = "";
    private String environment = "production";
    private String release = "";
    private boolean recovered = true;

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /** The project's DSN, {@code https://<key>@o0.ingest.sentry.io/<project>}. */
    public Builder dsn(String dsn) {
      this.dsn = Objects.requireNonNull(dsn, "dsn");
      return this;
    }

    /** Default {@code production}. */
    public Builder environment(String environment) {
      this.environment = Objects.requireNonNull(environment, "environment");
      return this;
    }

    /** The release, sent when set. */
    public Builder release(String release) {
      this.release = Objects.requireNonNull(release, "release");
      return this;
    }

    /** Also send recoveries, as info events. Default true. */
    public Builder recovered(boolean recovered) {
      this.recovered = recovered;
      return this;
    }

    /**
     * The options.
     *
     * @throws dev.cronwatch.CronwatchException without a DSN of the form {@code
     *     https://<key>@<host>/<project>}
     */
    public SentryOptions build() {
      // A pasted credential often carries a stray space or newline, which a header would refuse.
      String trimmed = Shared.trimmed(dsn);
      if (trimmed.isEmpty()) {
        throw Shared.invalid("Sentry needs a dsn");
      }
      String[] parsed = parseDsn(trimmed);
      return new SentryOptions(this, parsed[0], parsed[1]);
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "SentryOptions.Builder";
    }
  }
}
