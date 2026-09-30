package dev.cronwatch.alerts;

import dev.cronwatch.Alert;
import dev.cronwatch.Channel;
import dev.cronwatch.ChannelContext;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.post.Post;
import dev.cronwatch.json.JsObject;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * POSTs each alert as JSON to any URL ({@code alerts/webhook.ts}). The body is the {@link Alert} as
 * the SDK writes it ({@link Alert#toJson}). A redirect is an error: point the URL at where the
 * receiver really is.
 */
public final class Webhook implements Channel {
  private final WebhookOptions options;

  private Webhook(WebhookOptions options) {
    this.options = Objects.requireNonNull(options, "options");
  }

  /** The channel. */
  public static Webhook channel(WebhookOptions options) {
    return new Webhook(options);
  }

  /**
   * The webhook's signature of a body: the HMAC-SHA256 of the body with the secret, as lowercase
   * hex. The request carries it as {@code x-cronwatch-signature: sha256=<signature>}.
   */
  public static String signature(String secret, String body) {
    return Shared.hex(Shared.hmacSha256(Js.utf8(secret), body));
  }

  @Override
  public String name() {
    return "webhook";
  }

  @Override
  public void send(Alert alert, ChannelContext context) throws Exception {
    String body = alert.toJson();
    // A JavaScript object's keys: an exact name given again keeps its place.
    JsObject headers =
        new JsObject().set("content-type", "application/json").set("user-agent", "cronwatch");
    for (Map.Entry<String, String> h : options.headers) {
      // A pasted Authorization value often carries a stray space or newline, which fetch would
      // refuse.
      headers.set(h.getKey(), Js.trim(h.getValue()));
    }
    if (!options.secret.isEmpty()) {
      headers.set("x-cronwatch-signature", "sha256=" + signature(options.secret, body));
    }
    List<Map.Entry<String, String>> list = new ArrayList<>();
    for (Map.Entry<String, Object> e : headers.entries()) {
      list.add(Map.entry(e.getKey(), String.valueOf(e.getValue())));
    }
    // A redirect is refused, not followed: the headers (and the signature) would go with it.
    Post.Answer answer =
        Post.fetch(
            Shared.transport(options.transport, context),
            Post.timeoutMs(),
            options.url,
            list,
            body);
    if (!answer.ok()) {
      // Only the origin: a webhook URL's path or query often is the credential.
      throw Post.fail("Webhook " + Post.origin(options.url) + " answered " + answer.status());
    }
  }

  @Override
  public String toString() {
    return "Webhook";
  }
}
