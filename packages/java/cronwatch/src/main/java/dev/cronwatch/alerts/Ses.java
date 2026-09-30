package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.json.JsObject;
import dev.cronwatch.json.Json;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Sends alerts as email through Amazon SES, API v2 SendEmail ({@code alerts/ses.ts}): {@code POST
 * https://email.<region>.amazonaws.com/v2/email/outbound-emails}, signed with AWS Signature Version
 * 4, so no AWS SDK is needed.
 */
public final class Ses implements Channel {
  private final SesOptions options;
  private final String url;

  private Ses(SesOptions options) {
    this.options = Objects.requireNonNull(options, "options");
    this.url = "https://email." + options.region + ".amazonaws.com/v2/email/outbound-emails";
  }

  /** The channel. */
  public static Ses channel(SesOptions options) {
    return new Ses(options);
  }

  @Override
  public String name() {
    return "ses";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    Email.Mail mail = Email.compose(alert, options.email);
    JsObject body =
        new JsObject()
            .set("FromEmailAddress", mail.from())
            .set("Destination", new JsObject().set("ToAddresses", mail.to()))
            .set(
                "Content",
                new JsObject()
                    .set(
                        "Simple",
                        new JsObject()
                            .set("Subject", data(mail.subject()))
                            .set(
                                "Body",
                                new JsObject()
                                    .set("Text", data(mail.text()))
                                    .set("Html", data(mail.html())))));
    if (!options.configurationSetName.isEmpty()) {
      body.set("ConfigurationSetName", options.configurationSetName);
    }
    body.set("EmailTags", List.of(new JsObject().set("Name", "source").set("Value", "cronwatch")));
    String text = Json.stringify(body);
    List<Map.Entry<String, String>> headers =
        SigV4.sign(
            "POST",
            url,
            Shared.headers("content-type", "application/json"),
            text,
            options.region,
            "ses",
            options.now.getAsLong(),
            options.accessKeyId,
            options.secretAccessKey,
            options.sessionToken);
    Shared.send(
        Shared.transport(options.transport, context),
        "SES",
        url,
        headers,
        text,
        Arrays.asList(options.secretAccessKey, options.sessionToken));
  }

  private static JsObject data(String text) {
    return new JsObject().set("Data", text).set("Charset", "UTF-8");
  }

  @Override
  public String toString() {
    return "Ses";
  }
}
