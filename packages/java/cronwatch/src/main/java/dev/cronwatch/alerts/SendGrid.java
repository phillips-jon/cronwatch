package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/**
 * Sends alerts as email through SendGrid ({@code alerts/sendgrid.ts}): {@code POST
 * https://api.sendgrid.com/v3/mail/send} ({@code api.eu.sendgrid.com} for EU subusers) with a
 * bearer API key.
 */
public final class SendGrid implements Channel {
  private final SendGridOptions options;
  private final String url;

  private SendGrid(SendGridOptions options) {
    this.options = Objects.requireNonNull(options, "options");
    this.url =
        options.region.equals("eu")
            ? "https://api.eu.sendgrid.com/v3/mail/send"
            : "https://api.sendgrid.com/v3/mail/send";
  }

  /** The channel. */
  public static SendGrid channel(SendGridOptions options) {
    return new SendGrid(options);
  }

  @Override
  public String name() {
    return "sendgrid";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    Email.Mail mail = Email.compose(alert, options.email);
    List<Object> to = new ArrayList<>();
    for (String address : mail.to()) {
      to.add(Email.parseAddress(address));
    }
    JsObject body =
        new JsObject()
            .set("personalizations", List.of(new JsObject().set("to", to)))
            .set("from", Email.parseAddress(mail.from()))
            .set("subject", mail.subject())
            // text/plain must come before text/html.
            .set(
                "content",
                List.of(
                    new JsObject().set("type", "text/plain").set("value", mail.text()),
                    new JsObject().set("type", "text/html").set("value", mail.html())))
            .set("categories", List.of("cronwatch"));
    Shared.send(
        Shared.transport(options.transport, context),
        "SendGrid",
        url,
        Shared.headers(
            "content-type", "application/json", "authorization", "Bearer " + options.apiKey),
        Json.stringify(body),
        List.of(options.apiKey));
  }

  @Override
  public String toString() {
    return "SendGrid";
  }
}
