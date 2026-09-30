package dev.cronwatch.spring.web;

import dev.cronwatch.servlet.CronwatchFilter;
import dev.cronwatch.web.Endpoint;
import jakarta.servlet.Filter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import java.io.IOException;
import org.springframework.core.Ordered;

/**
 * The dashboard on a Spring MVC app: {@link CronwatchFilter} as a bean with an order, which Spring
 * Boot registers for every request; it answers those under its path and passes the rest down the
 * chain. Ahead of Spring Security's chain unless {@code cronwatch.web.order} moves it.
 */
public final class CronwatchServletFilter implements Filter, Ordered {
  private final CronwatchFilter filter;
  private final int order;

  /** {@code endpoint} at {@code path} within the context, at this filter order. */
  public CronwatchServletFilter(Endpoint endpoint, String path, int order) {
    this.filter = new CronwatchFilter(endpoint, path);
    this.order = order;
  }

  @Override
  public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
      throws IOException, ServletException {
    filter.doFilter(request, response, chain);
  }

  @Override
  public int getOrder() {
    return order;
  }

  @Override
  public String toString() {
    return "CronwatchServletFilter[" + filter + ", order=" + order + "]";
  }
}
