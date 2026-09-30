package dev.cronwatch.alerts;

import dev.cronwatch.internal.post.Post;
import dev.cronwatch.internal.post.WhatwgUrl;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.ByteBuffer;
import java.time.Duration;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Flow;
import java.util.concurrent.LinkedBlockingQueue;
import javax.net.ssl.SSLContext;
import org.jspecify.annotations.Nullable;

/**
 * The default {@link Transport}: one {@code java.net.http.HttpClient} over HTTP/1.1 that never
 * follows a redirect, uses no proxy, verifies TLS with the JDK's trust store and its host name
 * check (a certificate for an IP address checked against the address, never turned off), connects
 * within ten seconds, and runs on virtual threads. A client makes one when it first sends and
 * closes it with itself.
 *
 * <p>The body is read by a subscriber of its own that asks for one chunk at a time, so nothing past
 * what was asked for is buffered, and cancels its subscription when the answer is closed, which
 * closes the connection. No {@code accept-encoding} is sent, and nothing is decompressed, so a gzip
 * answer cannot grow in memory.
 *
 * <p>The JDK sets {@code host}, {@code connection}, {@code content-length}, {@code expect} and
 * {@code upgrade} itself and refuses to let a caller set them, so a header of those names (a
 * webhook's extra header, say) is dropped. It sends {@code User-Agent: Java-http-client/<version>}
 * unless the request names one.
 */
public final class JdkTransport implements Transport, AutoCloseable {
  /** The header names the JDK sets itself and refuses from a caller. */
  static final Set<String> RESTRICTED =
      Set.of("connection", "content-length", "expect", "host", "upgrade");

  private final ExecutorService executor;
  private final HttpClient client;

  /** A transport with the JDK's default TLS context and trust store. */
  public JdkTransport() {
    this(null);
  }

  /** A transport over this TLS context (the tests' own trust store). */
  JdkTransport(@Nullable SSLContext ssl) {
    this.executor =
        Executors.newThreadPerTaskExecutor(Thread.ofVirtual().name("cronwatch-http-", 0).factory());
    HttpClient.Builder b =
        HttpClient.newBuilder()
            .version(HttpClient.Version.HTTP_1_1)
            .followRedirects(HttpClient.Redirect.NEVER)
            .proxy(HttpClient.Builder.NO_PROXY)
            .connectTimeout(Duration.ofSeconds(10))
            .executor(executor);
    if (ssl != null) {
      b.sslContext(ssl);
    }
    this.client = b.build();
  }

  @Override
  public Response post(Request request) throws IOException, InterruptedException {
    URI uri = uri(request.url());
    HttpRequest.Builder b =
        HttpRequest.newBuilder(uri).POST(HttpRequest.BodyPublishers.ofByteArray(request.body()));
    for (Map.Entry<String, String> h : request.headers()) {
      if (!RESTRICTED.contains(h.getKey().toLowerCase(Locale.ROOT))) {
        try {
          b.header(h.getKey(), h.getValue());
        } catch (IllegalArgumentException refused) {
          // The JDK refuses a control character or one past U+00FF in a value, and quotes the
          // value, which may be a credential: named here by the header alone.
          throw new IOException(
              "the " + h.getKey() + " header's value holds a character the JDK will not send");
        }
      }
    }
    CompletableFuture<HttpResponse<Pull>> sent = client.sendAsync(b.build(), info -> new Pull());
    try {
      HttpResponse<Pull> response = sent.get();
      return new Response(response.statusCode(), response.body());
    } catch (InterruptedException e) {
      // Cancelling the exchange's future aborts the request (Java 16 and newer).
      sent.cancel(true);
      throw e;
    } catch (ExecutionException e) {
      Throwable cause = e.getCause();
      if (cause instanceof IOException io) {
        throw io;
      }
      throw new IOException(cause == null ? e : cause);
    }
  }

  /** The request's URL as the URI the JDK sends to, read as Post reads it. */
  private static URI uri(String url) throws IOException {
    if (WhatwgUrl.parse(url) instanceof WhatwgUrl.Special s) {
      URI uri = Post.uri(s.url());
      if (uri != null) {
        return uri;
      }
    }
    throw new IOException("only http and https URLs can be posted to, not this URL");
  }

  /**
   * Stops the client at once, interrupting what is in flight, and its threads with it. Sends made
   * after this fail.
   */
  @Override
  public void close() {
    client.shutdownNow();
    executor.shutdownNow();
  }

  @Override
  public String toString() {
    return "JdkTransport";
  }

  /** A body read a chunk at a time, each asked for as it is wanted. */
  private static final class Pull implements HttpResponse.BodySubscriber<Pull>, Response.Body {
    /** The end of the body, as an item of the queue. */
    private enum End {
      END
    }

    private final BlockingQueue<Object> items = new LinkedBlockingQueue<>();
    private final CountDownLatch subscribed = new CountDownLatch(1);
    private volatile Flow.@Nullable Subscription subscription;
    private volatile boolean ended;

    @Override
    public CompletionStage<Pull> getBody() {
      return CompletableFuture.completedStage(this);
    }

    @Override
    public void onSubscribe(Flow.Subscription s) {
      subscription = s;
      subscribed.countDown();
      if (ended) {
        // Closed before the body began: nothing of it is wanted.
        s.cancel();
      }
    }

    @Override
    public void onNext(List<ByteBuffer> buffers) {
      items.add(buffers);
    }

    @Override
    public void onError(Throwable error) {
      items.add(error);
    }

    @Override
    public void onComplete() {
      items.add(End.END);
    }

    @Override
    public byte @Nullable [] next() throws Exception {
      while (!ended) {
        Object item = items.poll();
        if (item == null) {
          subscribed.await();
          Flow.Subscription s = subscription;
          if (s != null) {
            s.request(1);
          }
          item = items.take();
        }
        if (item instanceof End) {
          ended = true;
          return null;
        }
        if (item instanceof Throwable t) {
          ended = true;
          throw t instanceof Exception e ? e : new IOException(t);
        }
        byte[] chunk = join(item);
        if (chunk.length > 0) {
          return chunk;
        }
      }
      return null;
    }

    private static byte[] join(Object item) {
      List<?> buffers = (List<?>) item;
      int n = 0;
      for (Object o : buffers) {
        n += ((ByteBuffer) o).remaining();
      }
      byte[] out = new byte[n];
      int at = 0;
      for (Object o : buffers) {
        ByteBuffer b = ((ByteBuffer) o).duplicate();
        int r = b.remaining();
        b.get(out, at, r);
        at += r;
      }
      return out;
    }

    /**
     * Cancels the subscription, which closes the connection, unless the body was read to its end.
     */
    @Override
    public void close() {
      if (!ended) {
        ended = true;
        Flow.Subscription s = subscription;
        if (s != null) {
          s.cancel();
        }
      }
    }
  }
}
