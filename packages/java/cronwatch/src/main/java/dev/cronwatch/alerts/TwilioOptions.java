package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.function.Function;
import org.jspecify.annotations.Nullable;

/** Configures {@link Twilio}. */
public final class TwilioOptions {
  final String accountSid;
  final String user;
  final String password;
  final String from;
  final String messagingServiceSid;
  final List<String> to;
  final boolean recovered;
  final double segments;
  final @Nullable Function<Alert, @Nullable String> link;
  final @Nullable Transport transport;

  private TwilioOptions(
      Builder b, String accountSid, String user, String password, List<String> to) {
    this.accountSid = accountSid;
    this.user = user;
    this.password = password;
    this.from = b.from;
    this.messagingServiceSid = b.messagingServiceSid;
    this.to = List.copyOf(to);
    this.recovered = b.recovered;
    this.segments = b.segments;
    this.link = b.link;
    this.transport = b.transport;
  }

  /** A builder with nothing set. */
  public static Builder builder() {
    return new Builder();
  }

  /** Names what is set, never a credential or a number. */
  @Override
  public String toString() {
    return "TwilioOptions[accountSid=set, "
        + (user.equals(accountSid) ? "authToken=set" : "apiKeySid=set, apiKeySecret=set")
        + ", to="
        + to.size()
        + ", recovered="
        + recovered
        + "]";
  }

  /** Builds {@link TwilioOptions}. */
  public static final class Builder extends ChannelBuilder<Builder> {
    private String accountSid = "";
    private String authToken = "";
    private String apiKeySid = "";
    private String apiKeySecret = "";
    private String from = "";
    private String messagingServiceSid = "";
    private List<String> to = new ArrayList<>();
    private boolean recovered;
    private double segments = Double.NaN;

    private Builder() {}

    @Override
    Builder self() {
      return this;
    }

    /** The account SID, {@code AC...}. It is in the URL whichever credentials sign the request. */
    public Builder accountSid(String accountSid) {
      this.accountSid = Objects.requireNonNull(accountSid, "accountSid");
      return this;
    }

    /** The account's auth token. Or give an API key SID and secret instead. */
    public Builder authToken(String authToken) {
      this.authToken = Objects.requireNonNull(authToken, "authToken");
      return this;
    }

    /** An API key SID, {@code SK...}, with {@link #apiKeySecret}, in place of the auth token. */
    public Builder apiKeySid(String apiKeySid) {
      this.apiKeySid = Objects.requireNonNull(apiKeySid, "apiKeySid");
      return this;
    }

    /** The API key's secret. */
    public Builder apiKeySecret(String apiKeySecret) {
      this.apiKeySecret = Objects.requireNonNull(apiKeySecret, "apiKeySecret");
      return this;
    }

    /** A Twilio number in E.164 form, {@code +15005550006}. Or give a messaging service SID. */
    public Builder from(String from) {
      this.from = Objects.requireNonNull(from, "from");
      return this;
    }

    /** A messaging service SID, {@code MG...}, in place of {@link #from}. */
    public Builder messagingServiceSid(String messagingServiceSid) {
      this.messagingServiceSid = Objects.requireNonNull(messagingServiceSid, "messagingServiceSid");
      return this;
    }

    /** One number in E.164 form, or several, replacing any given before; each gets its own text. */
    public Builder to(String... to) {
      return to(List.of(to));
    }

    /** The numbers, replacing any given before; each gets its own text. */
    public Builder to(List<String> to) {
      this.to = new ArrayList<>(to);
      return this;
    }

    /** Also text when a job recovers. Default false: a text is for what needs a person. */
    public Builder recovered(boolean recovered) {
      this.recovered = recovered;
      return this;
    }

    /** How many SMS segments a text may use, held to 1 to 10. Default 3. */
    public Builder segments(double segments) {
      this.segments = segments;
      return this;
    }

    /**
     * The options.
     *
     * @throws dev.cronwatch.CronwatchException without an account SID, credentials, a sender or a
     *     number
     */
    public TwilioOptions build() {
      // A pasted credential often carries a stray space or newline, which the Authorization
      // header would refuse.
      String sid = Shared.trimmed(accountSid);
      if (sid.isEmpty()) {
        throw Shared.invalid("Twilio needs an accountSid");
      }
      String keySid = Shared.trimmed(apiKeySid);
      String user = keySid.isEmpty() ? sid : keySid;
      String password = keySid.isEmpty() ? Shared.trimmed(authToken) : Shared.trimmed(apiKeySecret);
      if (password.isEmpty()) {
        throw Shared.invalid("Twilio needs an authToken, or an apiKeySid and apiKeySecret");
      }
      if (from.isEmpty() && messagingServiceSid.isEmpty()) {
        throw Shared.invalid("Twilio needs a from number or a messagingServiceSid");
      }
      List<String> numbers = new ArrayList<>();
      for (String n : to) {
        if (n != null && !Shared.trimmed(n).isEmpty()) {
          numbers.add(Shared.trimmed(n));
        }
      }
      if (numbers.isEmpty()) {
        throw Shared.invalid("Twilio needs at least one to number");
      }
      return new TwilioOptions(this, sid, user, password, numbers);
    }

    /** Names what is set, never a value. */
    @Override
    public String toString() {
      return "TwilioOptions.Builder";
    }
  }
}
