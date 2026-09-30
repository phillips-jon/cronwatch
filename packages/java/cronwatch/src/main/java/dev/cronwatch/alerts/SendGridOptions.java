package dev.cronwatch.alerts;

import java.util.Objects;
import org.jspecify.annotations.Nullable;

/** Configures {@link SendGrid}. */
public final class SendGridOptions {
  final String apiKey;
  final String region;
  final Email.Settings email;
  final @Nullable Transport transport;

  private SendGridOptions(Builder b, String apiKey, Email.Settings email) {
    this.apiKey = apiKey;
    this.region = b.region;
    this.email = email;
    this.transport = b.transport;
  }

  /** A builder with nothing set. */
  public static Builder builder() {
    return new Builder();
  }

  /** Names what is set, never the API key. */
  @Override
  public String toString() {
    return "SendGridOptions[apiKey=set, region=" + region + ", to=" + email.to().size() + "]";
  }

  /** Builds {@link SendGridOptions}. */
  public static final class Builder extends EmailBuilder<Builder> {
    private String apiKey = "";
    private String region = "us";

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /** An API key with Mail Send access, {@code SG...}. */
    public Builder apiKey(String apiKey) {
      this.apiKey = Objects.requireNonNull(apiKey, "apiKey");
      return this;
    }

    /** {@code eu} for an EU regional subuser. Default {@code us}. */
    public Builder region(String region) {
      this.region = Objects.requireNonNull(region, "region");
      return this;
    }

    /**
     * The options.
     *
     * @throws dev.cronwatch.CronwatchException without an API key, a from address or a to address
     */
    public SendGridOptions build() {
      // A pasted credential often carries a stray space or newline, which a header would refuse.
      String key = Shared.trimmed(apiKey);
      if (key.isEmpty()) {
        throw Shared.invalid("SendGrid needs an apiKey");
      }
      return new SendGridOptions(this, key, email("SendGrid"));
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "SendGridOptions.Builder";
    }
  }
}
