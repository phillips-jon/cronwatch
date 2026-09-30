package dev.cronwatch.alerts;

import dev.cronwatch.internal.post.Post;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;
import org.jspecify.annotations.Nullable;

/**
 * Sends one POST and answers its status and body, whatever the status: the one request every
 * channel and Claude triage make. {@link JdkTransport} over the JDK's {@code HttpClient} is the
 * default; an app that wants OkHttp, Apache HttpClient, a proxy or its own trust store writes one,
 * and gives it to the client ({@code Cronwatch.builder().transport(...)}) or to a channel's
 * options.
 *
 * <p>A transport must not follow redirects: a 3xx is an answer like any other, and the channel
 * fails on it, so credential headers never go where it points. The deadline (ten seconds for the
 * whole request) and the answer's cap (1 MiB) are held around the transport whatever it does: it is
 * called on a virtual thread of its own, interrupted past the deadline, and its body is read a
 * chunk at a time and closed at the cap. Its exceptions are rewritten so they name only the URL's
 * origin, since a webhook URL's path or query is often its credential.
 *
 * <p>What it is handed and answers are {@link Transport.Request} and {@link Transport.Response},
 * named for the transport so they are never mistaken for the dashboard's {@code
 * dev.cronwatch.web.Request} and {@code Response}, which a Spring or servlet app's code imports
 * beside them.
 */
@FunctionalInterface
public interface Transport {
  /**
   * Sends the request and answers once the answer's head has arrived; the body is read from the
   * response afterwards, a chunk at a time.
   *
   * @throws Exception when no answer came
   */
  Response post(Request request) throws Exception;

  /**
   * One POST, as a {@link Transport} is asked to send it: an http or https URL as the WHATWG URL
   * parser (and so fetch) writes it, the headers in the order they are sent, and the body. Its
   * {@code toString} shows the URL's origin, the header names and the body's length only, since the
   * rest carries the channel's credentials.
   */
  final class Request {
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
      return "Transport.Request[origin="
          + Post.origin(url)
          + ", headers="
          + names
          + ", body="
          + body.length
          + " bytes]";
    }
  }

  /**
   * An answer to a {@link Transport}'s request: its status, and its body as it arrives. Closing it
   * lets go of what is left of the body (the JDK transport cancels its subscription, which closes
   * the connection).
   */
  final class Response implements AutoCloseable {
    /** An answer's body, read a chunk at a time. */
    @FunctionalInterface
    public interface Body {
      /**
       * The next chunk, or null at the end. It may block until the chunk arrives, and must give up
       * when its thread is interrupted.
       *
       * @throws Exception when the body could not be read
       */
      byte @Nullable [] next() throws Exception;

      /**
       * Lets go of what is left of the body. Nothing by default.
       *
       * @throws Exception when that failed, which is ignored
       */
      default void close() throws Exception {}
    }

    private final int status;
    private final Body body;

    /** An answer of this status whose body arrives through {@code body}. */
    public Response(int status, Body body) {
      this.status = status;
      this.body = body;
    }

    /** An answer whose whole body is at hand. */
    public static Response of(int status, byte[] body) {
      byte[] copy = body.clone();
      AtomicBoolean read = new AtomicBoolean();
      return new Response(status, () -> read.getAndSet(true) ? null : copy.clone());
    }

    /** An answer whose whole body is this text, as UTF-8. */
    public static Response of(int status, String body) {
      return of(status, body.getBytes(StandardCharsets.UTF_8));
    }

    /** The status. */
    public int status() {
      return status;
    }

    /** The body, to read a chunk at a time. */
    public Body body() {
      return body;
    }

    /** Lets go of what is left of the body; a failure doing so is ignored. */
    @Override
    public void close() {
      try {
        body.close();
      } catch (Exception e) {
        // Nothing is left to read either way.
      }
    }

    @Override
    public String toString() {
      return "Transport.Response[" + status + "]";
    }
  }
}
