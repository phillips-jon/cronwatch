package dev.cronwatch.alerts;

import java.util.Objects;
import java.util.function.LongSupplier;
import org.jspecify.annotations.Nullable;

/** Configures {@link Ses}. */
public final class SesOptions {
  final String region;
  final String accessKeyId;
  final String secretAccessKey;
  final @Nullable String sessionToken;
  final String configurationSetName;
  final LongSupplier now;
  final Email.Settings email;
  final @Nullable Transport transport;

  private SesOptions(Builder b, String accessKeyId, String secretAccessKey, Email.Settings email) {
    this.region = b.region;
    this.accessKeyId = accessKeyId;
    this.secretAccessKey = secretAccessKey;
    String token = Shared.trimmed(b.sessionToken);
    this.sessionToken = token.isEmpty() ? null : token;
    this.configurationSetName = b.configurationSetName;
    this.now = b.now;
    this.email = email;
    this.transport = b.transport;
  }

  /** A builder with nothing set. */
  public static Builder builder() {
    return new Builder();
  }

  /** Names what is set, never a credential. */
  @Override
  public String toString() {
    return "SesOptions[region="
        + region
        + ", accessKeyId=set, secretAccessKey=set"
        + (sessionToken == null ? "" : ", sessionToken=set")
        + ", to="
        + email.to().size()
        + "]";
  }

  /** Builds {@link SesOptions}. */
  public static final class Builder extends EmailBuilder<Builder> {
    private String region = "";
    private String accessKeyId = "";
    private String secretAccessKey = "";
    private String sessionToken = "";
    private String configurationSetName = "";
    private LongSupplier now = System::currentTimeMillis;

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /** The SES region, {@code us-east-1} say. The from identity must be verified there. */
    public Builder region(String region) {
      this.region = Objects.requireNonNull(region, "region");
      return this;
    }

    /** The access key id. */
    public Builder accessKeyId(String accessKeyId) {
      this.accessKeyId = Objects.requireNonNull(accessKeyId, "accessKeyId");
      return this;
    }

    /** The secret access key. */
    public Builder secretAccessKey(String secretAccessKey) {
      this.secretAccessKey = Objects.requireNonNull(secretAccessKey, "secretAccessKey");
      return this;
    }

    /** For temporary credentials, an assumed role say. Sent and signed. */
    public Builder sessionToken(String sessionToken) {
      this.sessionToken = Objects.requireNonNull(sessionToken, "sessionToken");
      return this;
    }

    /** A configuration set for event publishing, if you use one. */
    public Builder configurationSetName(String configurationSetName) {
      this.configurationSetName =
          Objects.requireNonNull(configurationSetName, "configurationSetName");
      return this;
    }

    /** The clock requests are signed with, epoch milliseconds. For tests. */
    public Builder now(LongSupplier now) {
      this.now = Objects.requireNonNull(now, "now");
      return this;
    }

    /**
     * The options.
     *
     * @throws dev.cronwatch.CronwatchException without a region like {@code us-east-1}, the
     *     credentials, a from address or a to address
     */
    public SesOptions build() {
      if (region.isEmpty()) {
        throw Shared.invalid("SES needs a region");
      }
      for (int i = 0; i < region.length(); i++) {
        char c = region.charAt(i);
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) {
          throw Shared.invalid("SES needs a region like us-east-1");
        }
      }
      // A pasted credential often carries a stray space or newline, which would spoil the
      // signature.
      String id = Shared.trimmed(accessKeyId);
      String secret = Shared.trimmed(secretAccessKey);
      if (id.isEmpty() || secret.isEmpty()) {
        throw Shared.invalid("SES needs an accessKeyId and secretAccessKey");
      }
      return new SesOptions(this, id, secret, email("SES"));
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "SesOptions.Builder";
    }
  }
}
