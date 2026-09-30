package dev.cronwatch.alerts;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Function;
import javax.net.ssl.SSLContext;
import org.jspecify.annotations.Nullable;

/**
 * A local HTTP/1.1 server on a raw socket, so it can misbehave as a test needs: answer and close,
 * never answer, drip a body a byte at a time, or stream a large one while counting what the client
 * let it write. Over TLS when given a context.
 */
final class TestServer implements AutoCloseable {
  /** A request the server was sent: its header lines as sent, and its body. */
  @SuppressWarnings("ArrayRecordComponent")
  record Seen(List<Map.Entry<String, String>> headers, byte[] body) {
    /** The first header of this name, compared without regard to case, or null. */
    @Nullable String header(String name) {
      for (Map.Entry<String, String> h : headers) {
        if (h.getKey().equalsIgnoreCase(name)) {
          return h.getValue();
        }
      }
      return null;
    }
  }

  /** How the server answers. */
  sealed interface Reply {}

  /** An answer with a {@code content-length} and {@code connection: close}. */
  @SuppressWarnings("ArrayRecordComponent")
  record Answer(int status, List<Map.Entry<String, String>> headers, byte[] body) implements Reply {
    Answer(int status) {
      this(status, List.of(), new byte[0]);
    }
  }

  /** Takes the request and never answers. */
  record Hang() implements Reply {}

  /** Answers 500, chunked, then a byte every 50 ms for five seconds. */
  record Drip() implements Reply {}

  /**
   * Answers with a body of {@code length} bytes of {@code x}, written 64 KiB at a time: with a
   * {@code content-length}, chunked, or up to the connection's close.
   */
  record Stream(int status, long length, String framing) implements Reply {}

  private final ServerSocket socket;
  private final String url;
  private final List<Seen> seen = new CopyOnWriteArrayList<>();
  private final List<Socket> open = new CopyOnWriteArrayList<>();

  /** Bytes of a streamed body the server managed to write. */
  final AtomicLong written = new AtomicLong();

  /** When a streamed body's write failed because the client closed, or -1. */
  final AtomicLong stoppedAt = new AtomicLong(-1);

  private TestServer(ServerSocket socket, String scheme, Function<Seen, Reply> handler) {
    this.socket = socket;
    this.url = scheme + "://127.0.0.1:" + socket.getLocalPort();
    Thread.ofVirtual()
        .name("test-server")
        .start(
            () -> {
              while (!socket.isClosed()) {
                try {
                  Socket s = socket.accept();
                  open.add(s);
                  Thread.ofVirtual().start(() -> serve(s, handler));
                } catch (IOException e) {
                  return;
                }
              }
            });
  }

  /** A plain HTTP server. */
  static TestServer start(Function<Seen, Reply> handler) throws IOException {
    ServerSocket s = new ServerSocket();
    s.bind(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0));
    return new TestServer(s, "http", handler);
  }

  /** An HTTPS server over this context. */
  static TestServer tls(SSLContext context, Function<Seen, Reply> handler) throws IOException {
    ServerSocket s = context.getServerSocketFactory().createServerSocket();
    s.bind(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0));
    return new TestServer(s, "https", handler);
  }

  /** {@code http://127.0.0.1:<port>} (or https). */
  String url() {
    return url;
  }

  /** The requests seen so far. */
  List<Seen> seen() {
    return new ArrayList<>(seen);
  }

  private void serve(Socket s, Function<Seen, Reply> handler) {
    try (s) {
      InputStream in = s.getInputStream();
      ByteArrayOutputStream head = new ByteArrayOutputStream();
      int matched = 0;
      while (matched < 4) {
        int b = in.read();
        if (b < 0) {
          return;
        }
        head.write(b);
        matched = (b == "\r\n\r\n".charAt(matched)) ? matched + 1 : (b == '\r' ? 1 : 0);
      }
      String text = head.toString(StandardCharsets.ISO_8859_1);
      List<Map.Entry<String, String>> headers = new ArrayList<>();
      String[] lines = text.split("\r\n", -1);
      for (int i = 1; i < lines.length; i++) {
        int colon = lines[i].indexOf(':');
        if (colon > 0) {
          headers.add(
              Map.entry(lines[i].substring(0, colon), lines[i].substring(colon + 1).trim()));
        }
      }
      int length = 0;
      for (Map.Entry<String, String> h : headers) {
        if (h.getKey().toLowerCase(Locale.ROOT).equals("content-length")) {
          length = Integer.parseInt(h.getValue());
        }
      }
      byte[] body = in.readNBytes(length);
      Seen request = new Seen(List.copyOf(headers), body);
      seen.add(request);
      OutputStream out = s.getOutputStream();
      switch (handler.apply(request)) {
        case Answer a -> {
          StringBuilder h =
              new StringBuilder("HTTP/1.1 " + a.status() + " X\r\n")
                  .append("content-length: ")
                  .append(a.body().length)
                  .append("\r\nconnection: close\r\n");
          for (Map.Entry<String, String> e : a.headers()) {
            h.append(e.getKey()).append(": ").append(e.getValue()).append("\r\n");
          }
          out.write(h.append("\r\n").toString().getBytes(StandardCharsets.ISO_8859_1));
          out.write(a.body());
          out.flush();
        }
        case Hang h -> Thread.sleep(60_000);
        case Drip d -> {
          out.write(
              "HTTP/1.1 500 X\r\ntransfer-encoding: chunked\r\n\r\n"
                  .getBytes(StandardCharsets.ISO_8859_1));
          for (int i = 0; i < 100; i++) {
            out.write("1\r\nx\r\n".getBytes(StandardCharsets.ISO_8859_1));
            out.flush();
            Thread.sleep(50);
          }
        }
        case Stream st -> stream(out, st);
      }
    } catch (IOException | InterruptedException e) {
      // The client went away, which several tests arrange.
    }
  }

  private void stream(OutputStream out, Stream st) throws IOException {
    String head = "HTTP/1.1 " + st.status() + " X\r\n";
    head +=
        switch (st.framing()) {
          case "length" -> "content-length: " + st.length() + "\r\n";
          case "chunked" -> "transfer-encoding: chunked\r\n";
          default -> "connection: close\r\n";
        };
    out.write((head + "\r\n").getBytes(StandardCharsets.ISO_8859_1));
    byte[] chunk = "x".repeat(64 * 1024).getBytes(StandardCharsets.ISO_8859_1);
    long left = st.length();
    try {
      while (left > 0) {
        int n = (int) Math.min(chunk.length, left);
        if (st.framing().equals("chunked")) {
          out.write((Integer.toHexString(n) + "\r\n").getBytes(StandardCharsets.ISO_8859_1));
        }
        out.write(chunk, 0, n);
        if (st.framing().equals("chunked")) {
          out.write("\r\n".getBytes(StandardCharsets.ISO_8859_1));
        }
        out.flush();
        written.addAndGet(n);
        left -= n;
      }
      if (st.framing().equals("chunked")) {
        out.write("0\r\n\r\n".getBytes(StandardCharsets.ISO_8859_1));
        out.flush();
      }
    } catch (IOException e) {
      stoppedAt.set(written.get());
      throw e;
    }
  }

  @Override
  public void close() throws IOException {
    socket.close();
    for (Socket s : open) {
      s.close();
    }
  }
}
