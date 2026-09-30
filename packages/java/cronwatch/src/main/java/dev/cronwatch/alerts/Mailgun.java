package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * Sends alerts as email through Mailgun ({@code alerts/mailgun.ts}): {@code POST
 * https://api.mailgun.net/v3/<domain>/messages} ({@code api.eu.mailgun.net} for the EU region),
 * form encoded, with basic auth {@code api:<key>}.
 */
public final class Mailgun implements Channel {
  private final MailgunOptions options;
  private final String url;

  private Mailgun(MailgunOptions options) {
    this.options = Objects.requireNonNull(options, "options");
    String host =
        options.region.equals("eu") ? "https://api.eu.mailgun.net" : "https://api.mailgun.net";
    this.url = host + "/v3/" + Shared.encodeUriComponent(options.domain) + "/messages";
  }

  /** The channel. */
  public static Mailgun channel(MailgunOptions options) {
    return new Mailgun(options);
  }

  @Override
  public String name() {
    return "mailgun";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    Email.Mail mail = Email.compose(alert, options.email);
    List<Map.Entry<String, String>> form = new ArrayList<>();
    form.add(Map.entry("from", mail.from()));
    for (String address : mail.to()) {
      form.add(Map.entry("to", address));
    }
    form.add(Map.entry("subject", mail.subject()));
    form.add(Map.entry("text", mail.text()));
    form.add(Map.entry("html", mail.html()));
    form.add(Map.entry("o:tag", "cronwatch"));
    Shared.send(
        Shared.transport(options.transport, context),
        "Mailgun",
        url,
        Shared.headers(
            "content-type",
            "application/x-www-form-urlencoded",
            "authorization",
            Shared.basicAuth("api", options.apiKey)),
        Shared.form(form),
        List.of(options.apiKey));
  }

  @Override
  public String toString() {
    return "Mailgun";
  }
}
