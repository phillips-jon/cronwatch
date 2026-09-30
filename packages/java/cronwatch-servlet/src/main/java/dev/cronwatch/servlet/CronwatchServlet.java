package dev.cronwatch.servlet;

import dev.cronwatch.web.Endpoint;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletMapping;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.MappingMatch;
import java.util.Objects;

/**
 * A job's handler (or the dashboard) as a Jakarta {@link HttpServlet}, for a platform cron that
 * calls a URL. Every method is answered by the endpoint, so a {@code HEAD} or {@code OPTIONS} gets
 * the SDK's answer rather than the container's own.
 *
 * <pre>{@code
 * ServletRegistration.Dynamic s =
 *     servletContext.addServlet("nightly", new CronwatchServlet(nightly.handler(fn)));
 * s.addMapping("/cron/nightly");
 * }</pre>
 *
 * <p>For the dashboard a servlet mapped at {@code /cronwatch/*} finds its base path from the
 * mapping; {@link CronwatchFilter} is the one to use, as it can sit ahead of the app's security.
 */
public final class CronwatchServlet extends HttpServlet {
  private static final long serialVersionUID = 1L;

  @SuppressWarnings("serial") // not serialized: a servlet is made by the app, not deserialized
  private final Endpoint endpoint;

  /** The servlet over {@code endpoint}. */
  public CronwatchServlet(Endpoint endpoint) {
    this.endpoint = Objects.requireNonNull(endpoint, "endpoint");
  }

  @Override
  protected void service(HttpServletRequest req, HttpServletResponse res) {
    // Mapped at a path (/cronwatch/*), the dashboard is at the servlet path; mapped at the root, at
    // the context.
    HttpServletMapping mapping = req.getHttpServletMapping();
    boolean prefix = mapping != null && mapping.getMappingMatch() == MappingMatch.PATH;
    String context = req.getContextPath() == null ? "" : req.getContextPath();
    String mount = prefix ? context + req.getServletPath() : context;
    Exchange.write(endpoint.handle(Exchange.request(req, mount)), res);
  }

  @Override
  public String toString() {
    return "CronwatchServlet[" + endpoint + "]";
  }
}
