package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.function.Function;
import org.jspecify.annotations.Nullable;

/** Configures {@link Datadog}. */
public final class DatadogOptions {
  final String apiKey;
  final String url;
  final List<String> tags;
  final String host;
  final @Nullable Function<Alert, @Nullable String> link;
  final @Nullable Transport transport;

  private DatadogOptions(Builder b, String apiKey, String site) {
    this.apiKey = apiKey;
    this.url = "https://api." + site + "/api/v1/events";
    this.tags = List.copyOf(b.tags);
    this.host = b.host;
    this.link = b.link;
    this.transport = b.transport;
  }

  /** A builder with nothing set. */
  public static Builder builder() {
    return new Builder();
  }

  /** Names what is set, never the API key. */
  @Override
  public String toString() {
    return "DatadogOptions[apiKey=set, tags=" + tags.size() + "]";
  }

  /**
   * The site as the SDK reads it: a scheme, an {@code api.} or {@code app.} and trailing slashes
   * taken off, then letters, digits, dots, and hyphens only.
   */
  static String readSite(String given) {
    String site = given;
    if (site.startsWith("http://")) {
      site = site.substring(7);
    } else if (site.startsWith("https://")) {
      site = site.substring(8);
    }
    if (site.startsWith("api.") || site.startsWith("app.")) {
      site = site.substring(4);
    }
    int end = site.length();
    while (end > 0 && site.charAt(end - 1) == '/') {
      end--;
    }
    site = site.substring(0, end);
    boolean ok = !site.isEmpty();
    for (int i = 0; ok && i < site.length(); i++) {
      char c = site.charAt(i);
      ok =
          (c >= 'a' && c <= 'z')
              || (c >= 'A' && c <= 'Z')
              || (c >= '0' && c <= '9')
              || c == '.'
              || c == '-';
    }
    if (!ok) {
      throw Shared.invalid("Datadog needs a site like datadoghq.com");
    }
    return site;
  }

  /** Builds {@link DatadogOptions}. */
  public static final class Builder extends ChannelBuilder<Builder> {
    private String apiKey = "";
    private String site = "datadoghq.com";
    private List<String> tags = new ArrayList<>();
    private String host = "";

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /** An API key (not an application key). */
    public Builder apiKey(String apiKey) {
      this.apiKey = Objects.requireNonNull(apiKey, "apiKey");
      return this;
    }

    /**
     * Your Datadog site: {@code datadoghq.com} (the default), {@code datadoghq.eu}, {@code
     * us3.datadoghq.com}, {@code us5.datadoghq.com}, {@code ap1.datadoghq.com}, {@code
     * ddog-gov.com}.
     */
    public Builder site(String site) {
      this.site = Objects.requireNonNull(site, "site");
      return this;
    }

    /**
     * Extra tags, {@code env:prod} say, replacing any given before. Every event also has {@code
     * cronwatch}, {@code job:<name>}, and {@code alert:<type>}.
     */
    public Builder tags(String... tags) {
      this.tags = new ArrayList<>(List.of(tags));
      return this;
    }

    /** Associates the event with a host and its tags. */
    public Builder host(String host) {
      this.host = Objects.requireNonNull(host, "host");
      return this;
    }

    /**
     * The options.
     *
     * @throws dev.cronwatch.CronwatchException without an API key, or for a site that is not a host
     *     name
     */
    public DatadogOptions build() {
      // A pasted credential often carries a stray space or newline, which a header would refuse.
      String key = Shared.trimmed(apiKey);
      if (key.isEmpty()) {
        throw Shared.invalid("Datadog needs an apiKey");
      }
      return new DatadogOptions(this, key, readSite(site));
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "DatadogOptions.Builder";
    }
  }
}
