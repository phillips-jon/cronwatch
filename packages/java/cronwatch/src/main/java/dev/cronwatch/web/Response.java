package dev.cronwatch.web;

import dev.cronwatch.internal.js.Js;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import org.jspecify.annotations.Nullable;

/**
 * An answer: a status, headers in order (names lowercase, as fetch and HTTP/2 write them) and a
 * body. Immutable; {@link #withHeader} and {@link #withBody} give copies. The dashboard's answers
 * never carry a {@code content-length}; the server in front adds it. A job's handler function may
 * return one, which is then its answer.
 */
public final class Response {
  private final int status;
  private final List<Map.Entry<String, String>> headers;
  private final byte[] body;

  private Response(int status, List<Map.Entry<String, String>> headers, byte[] body) {
    this.status = status;
    this.headers = headers;
    this.body = body;
  }

  /** An answer with this status, no headers and no body. */
  public static Response of(int status) {
    return new Response(status, List.of(), new byte[0]);
  }

  /** A copy with a header added, its name lowercased. */
  public Response withHeader(String name, String value) {
    List<Map.Entry<String, String>> h = new ArrayList<>(headers);
    h.add(
        Map.entry(
            Objects.requireNonNull(name, "name").toLowerCase(Locale.ROOT),
            Objects.requireNonNull(value, "value")));
    return new Response(status, Collections.unmodifiableList(h), body);
  }

  /** A copy with this body. */
  public Response withBody(byte[] body) {
    return new Response(status, headers, body.clone());
  }

  /** A copy with this body, written as UTF-8. */
  public Response withBody(String body) {
    return new Response(status, headers, Js.utf8(body));
  }

  /** The status. */
  public int status() {
    return status;
  }

  /** The headers, in order, names lowercase. */
  public List<Map.Entry<String, String>> headers() {
    return headers;
  }

  /** The first value of a header, or null. */
  public @Nullable String header(String name) {
    for (Map.Entry<String, String> h : headers) {
      if (h.getKey().equalsIgnoreCase(name)) {
        return h.getValue();
      }
    }
    return null;
  }

  /** A copy of the body. */
  public byte[] body() {
    return body.clone();
  }

  /** The body's length in bytes. */
  public int bodyLength() {
    return body.length;
  }

  /** The body as text, with anything not UTF-8 replaced. */
  public String text() {
    return new String(body, StandardCharsets.UTF_8);
  }

  /** Names the status and the header names; the body and the header values are left out. */
  @Override
  public String toString() {
    List<String> names = new ArrayList<>();
    for (Map.Entry<String, String> h : headers) {
      names.add(h.getKey());
    }
    return "Response[status=" + status + ", headers=" + names + ", body=" + body.length + " bytes]";
  }

  /**
   * Writes the body to {@code out} without copying it, as an adapter sends it.
   *
   * @throws IOException when {@code out} fails
   */
  public void writeBody(OutputStream out) throws IOException {
    out.write(body);
  }
}
