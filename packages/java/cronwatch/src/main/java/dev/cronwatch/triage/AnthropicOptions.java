package dev.cronwatch.triage;

import dev.cronwatch.alerts.Transport;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/** Configures {@link Anthropic}'s triage. Every option has the SDK's default. */
public final class AnthropicOptions {
  final String apiKey;
  final String model;
  final String effort;
  final long maxTokens;
  final boolean fallbacks;
  final String context;
  final String baseUrl;
  final @Nullable Transport transport;

  private AnthropicOptions(Builder b) {
    this.apiKey = b.apiKey;
    this.model = b.model;
    this.effort = b.effort;
    this.maxTokens = b.maxTokens;
    this.fallbacks = b.fallbacks;
    this.context = b.context;
    this.baseUrl = b.baseUrl;
    this.transport = b.transport;
  }

  /** A builder with the SDK's defaults. */
  public static Builder builder() {
    return new Builder();
  }

  /** The SDK's defaults: the API key from {@code ANTHROPIC_API_KEY}, when triage runs. */
  public static AnthropicOptions defaults() {
    return new Builder().build();
  }

  /** Names what is set, never the API key or the context, which may describe the app. */
  @Override
  public String toString() {
    return "AnthropicOptions[apiKey="
        + (apiKey.isEmpty() ? "from ANTHROPIC_API_KEY" : "set")
        + ", model="
        + model
        + ", effort="
        + effort
        + ", maxTokens="
        + maxTokens
        + ", fallbacks="
        + fallbacks
        + "]";
  }

  /** Builds {@link AnthropicOptions}. */
  public static final class Builder {
    private String apiKey = "";
    private String model = Anthropic.DEFAULT_MODEL;
    private String effort = Anthropic.DEFAULT_EFFORT;
    private long maxTokens = Anthropic.DEFAULT_MAX_TOKENS;
    private boolean fallbacks = true;
    private String context = "";
    private String baseUrl = "";
    private @Nullable Transport transport;

    private Builder() {}

    /**
     * The API key. Default {@code ANTHROPIC_API_KEY}, read each time triage runs; trimmed of the
     * spaces and newlines a paste leaves.
     */
    public Builder apiKey(String apiKey) {
      this.apiKey = Objects.requireNonNull(apiKey, "apiKey");
      return this;
    }

    /** The model. Default {@code claude-opus-5}. */
    public Builder model(String model) {
      this.model = Objects.requireNonNull(model, "model");
      return this;
    }

    /**
     * How hard the model thinks: {@code low}, {@code medium} or {@code high}. Default {@code
     * medium}; a stack trace rarely needs more.
     */
    public Builder effort(String effort) {
      this.effort = Objects.requireNonNull(effort, "effort");
      return this;
    }

    /** The most tokens a diagnosis may use. Default 800; any other value is sent as given. */
    public Builder maxTokens(long maxTokens) {
      this.maxTokens = maxTokens;
      return this;
    }

    /**
     * Stops routing a policy refusal to Anthropic's default fallback model inside the same request
     * (on by default), for an account or gateway that rejects the beta.
     */
    public Builder noFallbacks() {
      this.fallbacks = false;
      return this;
    }

    /**
     * Anything the model should know about this app: "A Spring Boot service on Kubernetes with a
     * Postgres database."
     */
    public Builder context(String context) {
      this.context = Objects.requireNonNull(context, "context");
      return this;
    }

    /**
     * Where the API is. Default {@code ANTHROPIC_BASE_URL}, read each time triage runs, else {@code
     * https://api.anthropic.com}.
     */
    public Builder baseUrl(String baseUrl) {
      this.baseUrl = Objects.requireNonNull(baseUrl, "baseUrl");
      return this;
    }

    /** Sends the request; by default the client's transport. */
    public Builder transport(Transport transport) {
      this.transport = Objects.requireNonNull(transport, "transport");
      return this;
    }

    /** The options. */
    public AnthropicOptions build() {
      return new AnthropicOptions(this);
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "AnthropicOptions.Builder";
    }
  }
}
