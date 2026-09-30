package dev.cronwatch.servlet;

import dev.cronwatch.web.Endpoint;
import dev.cronwatch.web.Routes;
import jakarta.servlet.Filter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Objects;

/**
 * The dashboard as a Jakarta Servlet {@link Filter}: it answers the requests under its path (by
 * default {@code /cronwatch}, within the web app's context) and passes every other one down the
 * chain. A filter rather than a servlet, so it can sit ahead of the app's own servlets and security
 * (Spring Security's filter chain included, when it is ordered ahead of it).
 *
 * <pre>{@code
 * FilterRegistration.Dynamic f =
 *     servletContext.addFilter("cronwatch", new CronwatchFilter(cw.routes(), "/cronwatch"));
 * f.addMappingForUrlPatterns(null, false, "/cronwatch", "/cronwatch/*");
 * }</pre>
 *
 * <p>The request target is {@code getRequestURI()}, which the container leaves undecoded, with the
 * query from {@code getQueryString()}, and the dashboard's base path is the context path and the
 * filter's path (a {@code basePath} given to the routes wins). A body a filter ahead of it already
 * read as a form is taken from the container's parsed parameters. Tomcat and Jetty refuse an
 * encoded slash ({@code %2F}) in a path by default, so a job whose name holds a {@code /} cannot be
 * reached through the dashboard behind them unless the app allows it (Tomcat's {@code
 * encodedSolidusHandling}, Jetty's URI compliance).
 */
public final class CronwatchFilter implements Filter {
  private final Endpoint endpoint;
  private final String path;

  /** The dashboard at {@link Routes#DEFAULT_BASE_PATH} within the context. */
  public CronwatchFilter(Routes routes) {
    this(routes, Routes.DEFAULT_BASE_PATH);
  }

  /**
   * {@code endpoint} (the dashboard, or a job's handler) at {@code path} within the context, such
   * as {@code /cronwatch}; {@code ""} or {@code /} answers every request.
   */
  public CronwatchFilter(Endpoint endpoint, String path) {
    this.endpoint = Objects.requireNonNull(endpoint, "endpoint");
    String p = Objects.requireNonNull(path, "path");
    while (p.endsWith("/")) {
      p = p.substring(0, p.length() - 1);
    }
    this.path = p;
  }

  /** The path it answers under, within the context. */
  public String path() {
    return path;
  }

  @Override
  public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
      throws IOException, ServletException {
    if (!(request instanceof HttpServletRequest req)
        || !(response instanceof HttpServletResponse res)) {
      chain.doFilter(request, response);
      return;
    }
    String context = req.getContextPath() == null ? "" : req.getContextPath();
    String uri = req.getRequestURI();
    String within = uri.startsWith(context) ? uri.substring(context.length()) : uri;
    if (!path.isEmpty() && !within.equals(path) && !within.startsWith(path + "/")) {
      chain.doFilter(request, response);
      return;
    }
    Exchange.write(endpoint.handle(Exchange.request(req, context + path)), res);
  }

  @Override
  public String toString() {
    return "CronwatchFilter[path=" + path + ", endpoint=" + endpoint + "]";
  }
}
