package dev.cronwatch.alerts;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/** Configures {@link Webhook}. */
public final class WebhookOptions {
  final String url;
  final List<Map.Entry<String, String>> headers;
  final String secret;
  final @Nullable Transport transport;

  private WebhookOptions(Builder b) {
    this.url = b.url;
    this.headers = List.copyOf(b.headers);
    this.secret = b.secret;
    this.transport = b.transport;
  }

  /** A builder with nothing set. */
  public static Builder builder() {
    return new Builder();
  }

  /** Names what is set, never the URL, a header's value, or the secret. */
  @Override
  public String toString() {
    return "WebhookOptions[url=set, headers="
        + headers.size()
        + (secret.isEmpty() ? "" : ", secret=set")
        + "]";
  }

  /** Builds {@link WebhookOptions}. */
  public static final class Builder extends ChannelBuilder<Builder> {
    private String url = "";
    private final List<Map.Entry<String, String>> headers = new ArrayList<>();
    private String secret = "";

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /**
     * Where each alert is posted. Errors name only its origin, since a webhook URL's path or query
     * is often the credential.
     */
    public Builder url(String url) {
      this.url = Objects.requireNonNull(url, "url");
      return this;
    }

    /**
     * An extra request header, an {@code authorization} header say, sent in the order given; a name
     * given again keeps its place and takes the new value. Values are trimmed of the spaces and
     * newlines a paste leaves. {@code host}, {@code connection}, {@code content-length}, {@code
     * expect}, and {@code upgrade} are set by the JDK's transport itself, which drops them.
     */
    public Builder header(String name, String value) {
      Objects.requireNonNull(name, "name");
      Objects.requireNonNull(value, "value");
      for (int i = 0; i < headers.size(); i++) {
        if (headers.get(i).getKey().equals(name)) {
          headers.set(i, Map.entry(name, value));
          return this;
        }
      }
      headers.add(Map.entry(name, value));
      return this;
    }

    /**
     * When set, each request carries {@code x-cronwatch-signature: sha256=<hex>}, the HMAC-SHA256
     * of the raw body with this secret, so the receiver can verify it ({@link Webhook#signature}).
     */
    public Builder secret(String secret) {
      this.secret = Objects.requireNonNull(secret, "secret");
      return this;
    }

    /**
     * The options.
     *
     * @throws dev.cronwatch.CronwatchException without a URL
     */
    public WebhookOptions build() {
      if (url.isEmpty()) {
        throw Shared.invalid("Webhook needs a url");
      }
      return new WebhookOptions(this);
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "WebhookOptions.Builder";
    }
  }
}
