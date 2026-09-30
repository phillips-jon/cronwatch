package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.List;
import java.util.Objects;

/**
 * Sends alerts as email through Resend ({@code alerts/resend.ts}): {@code POST
 * https://api.resend.com/emails} with a bearer API key, and an idempotency key so the same alert
 * sent twice within 24 hours is delivered once.
 */
public final class Resend implements Channel {
  private static final String ENDPOINT = "https://api.resend.com/emails";

  private final ResendOptions options;

  private Resend(ResendOptions options) {
    this.options = Objects.requireNonNull(options, "options");
  }

  /** The channel. */
  public static Resend channel(ResendOptions options) {
    return new Resend(options);
  }

  @Override
  public String name() {
    return "resend";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    Email.Mail mail = Email.compose(alert, options.email);
    JsObject body =
        new JsObject()
            .set("from", mail.from())
            .set("to", mail.to())
            .set("subject", mail.subject())
            .set("text", mail.text())
            .set("html", mail.html());
    Shared.send(
        Shared.transport(options.transport, context),
        "Resend",
        ENDPOINT,
        Shared.headers(
            "content-type", "application/json",
            "authorization", "Bearer " + options.apiKey,
            "idempotency-key", "cronwatch-" + Shared.alertId(alert)),
        Json.stringify(body),
        List.of(options.apiKey));
  }

  @Override
  public String toString() {
    return "Resend";
  }
}
