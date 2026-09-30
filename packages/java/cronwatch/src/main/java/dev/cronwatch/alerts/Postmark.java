package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.List;
import java.util.Objects;

/**
 * Sends alerts as email through Postmark ({@code alerts/postmark.ts}): {@code POST
 * https://api.postmarkapp.com/email} with {@code X-Postmark-Server-Token}.
 */
public final class Postmark implements Channel {
  private static final String ENDPOINT = "https://api.postmarkapp.com/email";

  private final PostmarkOptions options;

  private Postmark(PostmarkOptions options) {
    this.options = Objects.requireNonNull(options, "options");
  }

  /** The channel. */
  public static Postmark channel(PostmarkOptions options) {
    return new Postmark(options);
  }

  @Override
  public String name() {
    return "postmark";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    Email.Mail mail = Email.compose(alert, options.email);
    JsObject body =
        new JsObject()
            .set("From", mail.from())
            .set("To", String.join(", ", mail.to()))
            .set("Subject", mail.subject())
            .set("TextBody", mail.text())
            .set("HtmlBody", mail.html())
            .set("MessageStream", options.messageStream)
            .set("Tag", "cronwatch");
    Shared.send(
        Shared.transport(options.transport, context),
        "Postmark",
        ENDPOINT,
        Shared.headers(
            "content-type", "application/json",
            "accept", "application/json",
            "x-postmark-server-token", options.serverToken),
        Json.stringify(body),
        List.of(options.serverToken));
  }

  @Override
  public String toString() {
    return "Postmark";
  }
}
