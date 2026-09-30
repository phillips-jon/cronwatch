package dev.cronwatch.webtest;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/**
 * A small HTTP/1.1 client over a socket, for the tests that go through a real server: it sends
 * exactly the headers given ({@code Host} included, which the JDK's client will not set) and reads
 * the answer as it arrives, with a length, chunked, or up to the close.
 */
public final class RawHttp {
  private RawHttp() {}

  /** An answer: the status, the headers in order and the body. */
  @SuppressWarnings("ArrayRecordComponent") // a test's answer, read once
  public record Answer(int status, List<Map.Entry<String, String>> headers, byte[] body) {
    /** The first value of a header, or null. */
    public @Nullable String header(String name) {
      for (Map.Entry<String, String> h : headers) {
        if (h.getKey().equalsIgnoreCase(name)) {
          return h.getValue();
        }
      }
      return null;
    }

    /** The body as UTF-8. */
    public String text() {
      return new String(body, StandardCharsets.UTF_8);
    }
  }

  /**
   * Sends one request on a connection of its own and reads the answer. {@code headers} are sent as
   * given, after {@code Host} when they do not name one.
   */
  public static Answer send(
      int port,
      String method,
      String target,
      List<Map.Entry<String, String>> headers,
      byte @Nullable [] body)
      throws IOException {
    try (Socket socket = new Socket(InetAddress.getLoopbackAddress(), port)) {
      socket.setSoTimeout(30_000);
      StringBuilder head = new StringBuilder();
      head.append(method).append(' ').append(target).append(" HTTP/1.1\r\n");
      boolean host = false;
      for (Map.Entry<String, String> h : headers) {
        host |= h.getKey().equalsIgnoreCase("host");
      }
      if (!host) {
        head.append("host: app.test\r\n");
      }
      for (Map.Entry<String, String> h : headers) {
        head.append(h.getKey()).append(": ").append(h.getValue()).append("\r\n");
      }
      if (body != null) {
        head.append("content-length: ").append(body.length).append("\r\n");
      } else if (!method.equals("GET") && !method.equals("HEAD")) {
        head.append("content-length: 0\r\n");
      }
      head.append("connection: close\r\n\r\n");
      OutputStream out = socket.getOutputStream();
      try {
        out.write(head.toString().getBytes(StandardCharsets.ISO_8859_1));
        if (body != null) {
          out.write(body);
        }
        out.flush();
      } catch (IOException e) {
        // A server may answer (a 413) and close before it has read the whole body; its answer is
        // still there to read.
      }
      return read(socket.getInputStream(), method.equals("HEAD"));
    }
  }

  private static String line(InputStream in) throws IOException {
    ByteArrayOutputStream b = new ByteArrayOutputStream();
    int c;
    while ((c = in.read()) != -1) {
      if (c == '\n') {
        break;
      }
      if (c != '\r') {
        b.write(c);
      }
    }
    return b.toString(StandardCharsets.ISO_8859_1);
  }

  private static Answer read(InputStream in, boolean head) throws IOException {
    String status = line(in);
    while (status.startsWith("HTTP/1.1 1")) {
      // An interim answer: skip it and its headers.
      while (!line(in).isEmpty()) {
        // Nothing to keep.
      }
      status = line(in);
    }
    String[] parts = status.split(" ", 3);
    int code = Integer.parseInt(parts[1]);
    List<Map.Entry<String, String>> headers = new ArrayList<>();
    long length = -1;
    boolean chunked = false;
    for (String l = line(in); !l.isEmpty(); l = line(in)) {
      int colon = l.indexOf(':');
      String name = l.substring(0, colon).trim();
      String value = l.substring(colon + 1).trim();
      headers.add(Map.entry(name, value));
      if (name.equalsIgnoreCase("content-length")) {
        length = Long.parseLong(value);
      } else if (name.equalsIgnoreCase("transfer-encoding") && value.equalsIgnoreCase("chunked")) {
        chunked = true;
      }
    }
    byte[] body;
    if (head || code == 204 || code == 304) {
      body = new byte[0];
    } else if (chunked) {
      ByteArrayOutputStream b = new ByteArrayOutputStream();
      while (true) {
        String size = line(in);
        int semi = size.indexOf(';');
        int n = Integer.parseInt((semi < 0 ? size : size.substring(0, semi)).trim(), 16);
        if (n == 0) {
          while (!line(in).isEmpty()) {
            // Trailers.
          }
          break;
        }
        b.write(in.readNBytes(n));
        line(in);
      }
      body = b.toByteArray();
    } else if (length >= 0) {
      body = in.readNBytes((int) length);
    } else {
      body = in.readAllBytes();
    }
    return new Answer(code, headers, body);
  }
}
