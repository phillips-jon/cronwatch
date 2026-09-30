package dev.cronwatch.alerts;

import dev.cronwatch.internal.post.Post;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * One POST, as a {@link Transport} is asked to send it: an http or https URL as the WHATWG URL
 * parser (and so fetch) writes it, the headers in the order they are sent, and the body. Its {@code
 * toString} shows the URL's origin, the header names and the body's length only, since the rest
 * carries the channel's credentials.
 */
public final class Request {
  private final String url;
  private final List<Map.Entry<String, String>> headers;
  private final byte[] body;

  /** A request of these parts. The headers are copied, and so is the body. */
  public Request(String url, List<Map.Entry<String, String>> headers, byte[] body) {
    this.url = Objects.requireNonNull(url, "url");
    this.headers = List.copyOf(headers);
    this.body = body.clone();
  }

  /** The URL. Its path or query may be a credential: never quote it. */
  public String url() {
    return url;
  }

  /** The headers in the order they are sent, names as the SDK writes them. */
  public List<Map.Entry<String, String>> headers() {
    return headers;
  }

  /** The value of the first header of this name, compared without regard to case, or null. */
  public @Nullable String header(String name) {
    for (Map.Entry<String, String> h : headers) {
      if (h.getKey().equalsIgnoreCase(name)) {
        return h.getValue();
      }
    }
    return null;
  }

  /** The body: UTF-8 (JSON, a form, a Sentry envelope). A copy. */
  public byte[] body() {
    return body.clone();
  }

  /** The URL's origin, the header names and the body's length. */
  @Override
  public String toString() {
    List<String> names = new ArrayList<>(headers.size());
    for (Map.Entry<String, String> h : headers) {
      names.add(h.getKey());
    }
    return "Request[origin="
        + Post.origin(url)
        + ", headers="
        + names
        + ", body="
        + body.length
        + " bytes]";
  }
}
