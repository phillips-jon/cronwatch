package dev.cronwatch.alerts;

import java.util.Objects;
import org.jspecify.annotations.Nullable;

/** Configures {@link Resend}. */
public final class ResendOptions {
  final String apiKey;
  final Email.Settings email;
  final @Nullable Transport transport;

  private ResendOptions(String apiKey, Email.Settings email, @Nullable Transport transport) {
    this.apiKey = apiKey;
    this.email = email;
    this.transport = transport;
  }

  /** A builder with nothing set. */
  public static Builder builder() {
    return new Builder();
  }

  /** Names what is set, never the API key. */
  @Override
  public String toString() {
    return "ResendOptions[apiKey=set, to=" + email.to().size() + "]";
  }

  /** Builds {@link ResendOptions}. */
  public static final class Builder extends EmailBuilder<Builder> {
    private String apiKey = "";

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /** An API key from resend.com/api-keys, {@code re_...}. */
    public Builder apiKey(String apiKey) {
      this.apiKey = Objects.requireNonNull(apiKey, "apiKey");
      return this;
    }

    /**
     * The options.
     *
     * @throws dev.cronwatch.CronwatchException without an API key, a from address or a to address
     */
    public ResendOptions build() {
      // A pasted credential often carries a stray space or newline, which a header would refuse.
      String key = Shared.trimmed(apiKey);
      if (key.isEmpty()) {
        throw Shared.invalid("Resend needs an apiKey");
      }
      return new ResendOptions(key, email("Resend"), transport);
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "ResendOptions.Builder";
    }
  }
}
