package dev.cronwatch.alerts;

import java.util.Objects;
import org.jspecify.annotations.Nullable;

/** Configures {@link Postmark}. */
public final class PostmarkOptions {
  final String serverToken;
  final String messageStream;
  final Email.Settings email;
  final @Nullable Transport transport;

  private PostmarkOptions(Builder b, String serverToken, Email.Settings email) {
    this.serverToken = serverToken;
    this.messageStream = b.messageStream;
    this.email = email;
    this.transport = b.transport;
  }

  /** A builder with nothing set. */
  public static Builder builder() {
    return new Builder();
  }

  /** Names what is set, never the server token. */
  @Override
  public String toString() {
    return "PostmarkOptions[serverToken=set, to=" + email.to().size() + "]";
  }

  /** Builds {@link PostmarkOptions}. */
  public static final class Builder extends EmailBuilder<Builder> {
    private String serverToken = "";
    private String messageStream = "outbound";

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /** A server API token, from the server's API Tokens tab. */
    public Builder serverToken(String serverToken) {
      this.serverToken = Objects.requireNonNull(serverToken, "serverToken");
      return this;
    }

    /** The message stream. Default {@code outbound}, the transactional stream. */
    public Builder messageStream(String messageStream) {
      this.messageStream = Objects.requireNonNull(messageStream, "messageStream");
      return this;
    }

    /**
     * The options.
     *
     * @throws dev.cronwatch.CronwatchException without a server token, a from address or a to
     *     address
     */
    public PostmarkOptions build() {
      // A pasted credential often carries a stray space or newline, which a header would refuse.
      String token = Shared.trimmed(serverToken);
      if (token.isEmpty()) {
        throw Shared.invalid("Postmark needs a serverToken");
      }
      return new PostmarkOptions(this, token, email("Postmark"));
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "PostmarkOptions.Builder";
    }
  }
}
