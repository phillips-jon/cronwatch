package dev.cronwatch.spring;

import dev.cronwatch.Channel;
import dev.cronwatch.Cronwatch;
import dev.cronwatch.CronwatchException;
import dev.cronwatch.Deliver;
import dev.cronwatch.ErrorHandler;
import dev.cronwatch.JobOptions;
import dev.cronwatch.Source;
import dev.cronwatch.Triage;
import dev.cronwatch.jdbc.SqlStore;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import java.lang.reflect.Method;
import java.util.List;
import java.util.Locale;
import javax.sql.DataSource;
import org.jspecify.annotations.Nullable;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.core.env.Environment;

/**
 * The client as a bean, from {@code cronwatch.*} properties and the app's own beans: a {@link
 * Store} bean is the store (else {@code cronwatch.store}), every {@link Channel} bean is a channel
 * (else the console), and a {@link Triage}, {@link Source} beans and an {@link ErrorHandler} are
 * used when the app has them. When neither {@code CRONWATCH_ENV} nor {@code APP_ENV} is set, the
 * environment is the app's active Spring profile ({@code dev} and {@code local} are development,
 * {@code prod} production). The client is closed when the context closes. An app's own {@link
 * Cronwatch} bean replaces this one, and {@code cronwatch.enabled=false} turns the starter off.
 */
@AutoConfiguration
@ConditionalOnProperty(prefix = "cronwatch", name = "enabled", matchIfMissing = true)
@EnableConfigurationProperties(CronwatchProperties.class)
public class CronwatchAutoConfiguration {
  private static final System.Logger LOGGER = System.getLogger("dev.cronwatch.spring");

  /** Made by Spring. */
  public CronwatchAutoConfiguration() {}

  /** The client. */
  @Bean(destroyMethod = "close")
  @ConditionalOnMissingBean
  public Cronwatch cronwatch(
      CronwatchProperties properties,
      Environment environment,
      ObjectProvider<Store> stores,
      ObjectProvider<DataSource> dataSources,
      ObjectProvider<Channel> channels,
      ObjectProvider<Triage> triage,
      ObjectProvider<Source> sources,
      ObjectProvider<ErrorHandler> onError) {
    Cronwatch.Builder b = Cronwatch.builder();
    String profile = profile(environment.getActiveProfiles());
    if (profile != null) {
      b.environment(profile);
    }
    Store store = stores.getIfUnique();
    if (store == null) {
      store = store(properties, dataSources.getIfUnique());
    }
    if (store != null) {
      b.store(store);
    }
    List<Channel> given = channels.orderedStream().toList();
    if (!given.isEmpty()) {
      b.alerts(given);
    }
    Triage t = triage.getIfUnique();
    if (t != null) {
      b.triage(t);
    }
    sources.orderedStream().forEach(b::source);
    ErrorHandler handler = onError.getIfUnique();
    if (handler != null) {
      b.onError(handler);
    }
    if (properties.getRetention() != null) {
      b.retention(properties.getRetention());
    }
    if (properties.getCronSecret() != null) {
      b.cronSecret(properties.getCronSecret());
    }
    b.deliver(deliver(properties.getDeliver()));
    if (!properties.isRedact()) {
      b.noRedaction();
    }
    if (!properties.isShutdownHook()) {
      b.noShutdownHook();
    }
    JobOptions defaults = defaults(properties.getDefaults());
    if (defaults != null) {
      b.defaults(defaults);
    }
    return b.build();
  }

  /**
   * The active profile the environment is read from: the first that names development or
   * production, as the client reads a name, else the first; null when none is active.
   */
  static @Nullable String profile(String[] active) {
    for (String p : active) {
      switch (p.strip().toLowerCase(Locale.ROOT)) {
        case "development", "dev", "local", "test", "testing", "production", "prod" -> {
          return p;
        }
        default -> {
          // Not one the client reads as either; the first is taken below.
        }
      }
    }
    return active.length == 0 ? null : active[0];
  }

  private static Deliver deliver(String text) {
    return switch (text.trim().toLowerCase(Locale.ROOT)) {
      case "now" -> Deliver.NOW;
      case "at-check", "at_check", "atcheck" -> Deliver.AT_CHECK;
      default ->
          throw CronwatchException.invalid(
              "cronwatch.deliver must be now or at-check (got " + text + ")");
    };
  }

  private static @Nullable JobOptions defaults(CronwatchProperties.Defaults d) {
    JobOptions options = JobOptions.builder();
    boolean any = false;
    if (d.getGrace() != null) {
      options.grace(d.getGrace());
      any = true;
    }
    if (d.getTimeout() != null) {
      options.timeout(d.getTimeout());
      any = true;
    }
    if (d.getTimezone() != null) {
      options.timezone(d.getTimezone());
      any = true;
    }
    if (d.getFailuresBeforeAlert() != null) {
      options.failuresBeforeAlert(d.getFailuresBeforeAlert());
      any = true;
    }
    return any ? options : null;
  }

  /** The store {@code cronwatch.store} names; null for the client's default. */
  private static @Nullable Store store(
      CronwatchProperties properties, @Nullable DataSource dataSource) {
    CronwatchProperties.StoreKind kind = properties.getStore();
    if (kind == CronwatchProperties.StoreKind.MEMORY) {
      return new MemoryStore();
    }
    if (dataSource == null) {
      if (kind == CronwatchProperties.StoreKind.JDBC) {
        throw CronwatchException.invalid(
            "cronwatch.store=jdbc needs one DataSource bean; the app has none, or several");
      }
      return null;
    }
    try {
      SqlStore sql = SqlStore.of(plain(dataSource));
      String prefix = properties.getTablePrefix();
      return prefix == null ? sql : sql.prefix(prefix);
    } catch (CronwatchException e) {
      if (kind == CronwatchProperties.StoreKind.JDBC) {
        throw e;
      }
      LOGGER.log(
          System.Logger.Level.WARNING,
          "[cronwatch] the app's DataSource cannot hold CronWatch's tables ("
              + e.getMessage()
              + "); using the in-memory store. Set cronwatch.store=memory to say so, or give a"
              + " Store bean.");
      return null;
    }
  }

  /**
   * The {@code DataSource} underneath Spring's {@code TransactionAwareDataSourceProxy}, which would
   * hand the store the connection of a transaction the app has open, so a failed run would vanish
   * with the rollback it caused. Found by name, since spring-jdbc is the app's.
   */
  static DataSource plain(DataSource dataSource) {
    DataSource ds = dataSource;
    for (int depth = 0; depth < 8; depth++) {
      if (!ds.getClass()
          .getName()
          .equals("org.springframework.jdbc.datasource.TransactionAwareDataSourceProxy")) {
        return ds;
      }
      try {
        Method target = ds.getClass().getMethod("getTargetDataSource");
        if (!(target.invoke(ds) instanceof DataSource inner)) {
          return ds;
        }
        ds = inner;
      } catch (ReflectiveOperationException | RuntimeException e) {
        return ds;
      }
    }
    return ds;
  }
}
