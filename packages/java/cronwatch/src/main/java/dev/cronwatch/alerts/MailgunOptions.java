package dev.cronwatch.alerts;

import java.util.Objects;
import org.jspecify.annotations.Nullable;

/** Configures {@link Mailgun}. */
public final class MailgunOptions {
  final String apiKey;
  final String domain;
  final String region;
  final Email.Settings email;
  final @Nullable Transport transport;

  private MailgunOptions(Builder b, String apiKey, Email.Settings email) {
    this.apiKey = apiKey;
    this.domain = b.domain;
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
    return "MailgunOptions[apiKey=set, region=" + region + ", to=" + email.to().size() + "]";
  }

  /** Builds {@link MailgunOptions}. */
  public static final class Builder extends EmailBuilder<Builder> {
    private String apiKey = "";
    private String domain = "";
    private String region = "us";

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /** A sending or account API key. */
    public Builder apiKey(String apiKey) {
      this.apiKey = Objects.requireNonNull(apiKey, "apiKey");
      return this;
    }

    /** The sending domain, {@code mg.example.com}. */
    public Builder domain(String domain) {
      this.domain = Objects.requireNonNull(domain, "domain");
      return this;
    }

    /** {@code eu} for a domain in the EU region. Default {@code us}. */
    public Builder region(String region) {
      this.region = Objects.requireNonNull(region, "region");
      return this;
    }

    /**
     * The options.
     *
     * @throws dev.cronwatch.CronwatchException without an API key, a domain, a from address, or a
     *     to address
     */
    public MailgunOptions build() {
      // A pasted credential often carries a stray space or newline, which a header would refuse.
      String key = Shared.trimmed(apiKey);
      if (key.isEmpty()) {
        throw Shared.invalid("Mailgun needs an apiKey");
      }
      if (domain.isEmpty()) {
        throw Shared.invalid("Mailgun needs a domain");
      }
      return new MailgunOptions(this, key, email("Mailgun"));
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "MailgunOptions.Builder";
    }
  }
}
