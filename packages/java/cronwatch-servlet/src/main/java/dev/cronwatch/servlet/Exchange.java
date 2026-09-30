package dev.cronwatch.servlet;

import dev.cronwatch.web.Adapters;
import dev.cronwatch.web.Request;
import dev.cronwatch.web.Response;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Enumeration;
import java.util.Map;
import org.jspecify.annotations.Nullable;

/** A servlet request as a {@link Request}, and a {@link Response} written back. */
final class Exchange {
  private Exchange() {}

  /**
   * The request, its body read only when a route wants it. The target is {@code getRequestURI()},
   * which the container leaves undecoded, with the query from {@code getQueryString()}; {@code
   * mount} is where the dashboard is, context path included.
   */
  static Request request(HttpServletRequest req, @Nullable String mount) {
    String target = Adapters.target(req.getRequestURI(), req.getQueryString());
    Request.Builder b = Request.builder(req.getMethod(), target).tls(req.isSecure());
    if (mount != null) {
      b.mount(mount);
    }
    Enumeration<String> names = req.getHeaderNames();
    while (names != null && names.hasMoreElements()) {
      String name = names.nextElement();
      Enumeration<String> values = req.getHeaders(name);
      while (values != null && values.hasMoreElements()) {
        b.header(name, values.nextElement());
      }
    }
    long length = req.getContentLengthLong();
    b.body(length, limit -> read(req, limit));
    return b.build();
  }

  /**
   * The body up to {@code limit} and one byte. A body a filter ahead of the dashboard already read
   * as a form (Spring's {@code HiddenHttpMethodFilter}, anything that called {@code getParameter})
   * leaves nothing to read; the container's parsed parameters are then taken, less those of the
   * query, which the servlet specification puts first.
   */
  private static byte[] read(HttpServletRequest req, int limit) throws IOException {
    InputStream in = req.getInputStream();
    byte[] data = in.readNBytes(limit + 1);
    if (data.length > 0) {
      return data;
    }
    String type = req.getContentType();
    if (type == null || !type.contains("application/x-www-form-urlencoded")) {
      return data;
    }
    return Adapters.formBody(req.getParameterMap(), req.getQueryString());
  }

  /** Writes the answer. A client that went away before it was written is not reported. */
  static void write(Response answer, HttpServletResponse res) {
    try {
      res.setStatus(answer.status());
      for (Map.Entry<String, String> h : answer.headers()) {
        res.addHeader(h.getKey(), h.getValue());
      }
      res.setContentLength(answer.bodyLength());
      if (answer.bodyLength() > 0) {
        OutputStream out = res.getOutputStream();
        answer.writeBody(out);
        out.flush();
      }
    } catch (IOException e) {
      // The client went away: nothing to report.
    }
  }
}
