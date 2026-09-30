package dev.cronwatch.spring.web;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.web.Routes;
import dev.cronwatch.web.RoutesOptions;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.autoconfigure.condition.ConditionalOnWebApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * The dashboard on the app's own server, from {@code cronwatch.web.*}: on Spring MVC through the
 * servlet filter, on WebFlux through a {@code WebFilter}, at {@code cronwatch.web.path} ({@code
 * /cronwatch} by default) within the app's context, ahead of Spring Security's filter chain. It
 * uses the app's {@link Cronwatch} bean, and a {@link Routes} bean of the app's own replaces the
 * one made here; {@code cronwatch.web.enabled=false} turns it off.
 */
@AutoConfiguration(afterName = "dev.cronwatch.spring.CronwatchAutoConfiguration")
@ConditionalOnWebApplication
@ConditionalOnBean(Cronwatch.class)
@ConditionalOnProperty(prefix = "cronwatch.web", name = "enabled", matchIfMissing = true)
@EnableConfigurationProperties(CronwatchWebProperties.class)
public class CronwatchWebAutoConfiguration {
  /** Made by Spring. */
  public CronwatchWebAutoConfiguration() {}

  /**
   * The dashboard's routes: the token from {@code cronwatch.web.token}, else {@code
   * CRONWATCH_TOKEN}, or none with {@code cronwatch.web.open}; the base path is found from where
   * the filter is.
   */
  @Bean
  @ConditionalOnMissingBean
  public Routes cronwatchRoutes(Cronwatch cronwatch, CronwatchWebProperties properties) {
    RoutesOptions.Builder options = RoutesOptions.builder();
    if (properties.isOpen()) {
      options.noToken();
    } else if (properties.getToken() != null) {
      options.token(properties.getToken());
    }
    if (properties.getOrigin() != null) {
      options.origin(properties.getOrigin());
    }
    if (properties.isTrustProxy()) {
      options.trustProxy();
    }
    return cronwatch.routes(options.build());
  }

  /** On Spring MVC: the servlet filter. */
  @Configuration(proxyBeanMethods = false)
  @ConditionalOnWebApplication(type = ConditionalOnWebApplication.Type.SERVLET)
  @ConditionalOnClass(name = "jakarta.servlet.Filter")
  static class Servlet {
    @Bean
    @ConditionalOnMissingBean
    CronwatchServletFilter cronwatchServletFilter(
        Routes routes, CronwatchWebProperties properties) {
      return new CronwatchServletFilter(routes, properties.getPath(), properties.getOrder());
    }
  }

  /** On WebFlux: a {@code WebFilter}. */
  @Configuration(proxyBeanMethods = false)
  @ConditionalOnWebApplication(type = ConditionalOnWebApplication.Type.REACTIVE)
  @ConditionalOnClass(name = "reactor.core.publisher.Mono")
  static class Reactive {
    @Bean
    @ConditionalOnMissingBean
    CronwatchReactiveFilter cronwatchReactiveFilter(
        Routes routes, CronwatchWebProperties properties) {
      return new CronwatchReactiveFilter(routes, properties.getPath(), properties.getOrder());
    }
  }
}
