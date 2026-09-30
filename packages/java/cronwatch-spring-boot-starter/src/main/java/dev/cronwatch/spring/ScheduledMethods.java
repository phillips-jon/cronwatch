package dev.cronwatch.spring;

import java.lang.reflect.Method;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.jspecify.annotations.Nullable;
import org.springframework.aop.framework.AopProxyUtils;
import org.springframework.beans.BeansException;
import org.springframework.beans.factory.BeanFactory;
import org.springframework.beans.factory.BeanFactoryAware;
import org.springframework.beans.factory.config.ConfigurableBeanFactory;
import org.springframework.beans.factory.config.DestructionAwareBeanPostProcessor;
import org.springframework.beans.factory.config.EmbeddedValueResolver;
import org.springframework.context.ApplicationListener;
import org.springframework.context.event.ContextClosedEvent;
import org.springframework.core.MethodIntrospector;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.AnnotatedElementUtils;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.scheduling.annotation.Schedules;
import org.springframework.util.ClassUtils;

/**
 * Finds every {@code @Scheduled} (and {@code @Schedules}) method of every bean, reading the
 * annotations as Spring's own post-processor does: placeholders and expressions resolved, {@code
 * cron = "-"} disabled, {@code zone}, {@code fixedRate}, {@code fixedDelay} and their {@code
 * String} forms, and {@code timeUnit}. It only collects what it finds, so it depends on nothing and
 * starts no work; {@code CronwatchScheduling} declares the jobs once the beans are made. A bean
 * destroyed while the app runs is said to have gone, and its jobs are declared again without their
 * schedules; when the context closes, nothing is.
 */
public final class ScheduledMethods
    implements DestructionAwareBeanPostProcessor,
        BeanFactoryAware,
        ApplicationListener<ContextClosedEvent>,
        Ordered {
  /** How a {@code @Scheduled} annotation schedules its method. */
  enum Kind {
    CRON,
    FIXED_RATE,
    FIXED_DELAY,
    ONCE
  }

  /** One {@code @Scheduled} annotation as Spring reads it. */
  record Schedule(Kind kind, String cron, String zone, long millis) {}

  /**
   * One scheduled method of one bean.
   *
   * @param beanName the bean's name
   * @param userClass the bean's class, not its proxy's
   * @param method the method
   * @param schedules each of its {@code @Scheduled} annotations that schedules it
   * @param job its {@code @CronwatchJob}, or null
   * @param reactive whether Spring observes it around a subscription rather than its work
   * @param locked whether it carries ShedLock's {@code @SchedulerLock}
   */
  record Found(
      String beanName,
      Class<?> userClass,
      Method method,
      List<Schedule> schedules,
      @Nullable CronwatchJob job,
      boolean reactive,
      boolean locked) {}

  private static final Pattern SIMPLE = Pattern.compile("(-?\\d+)(ns|us|ms|s|m|h|d)");

  private final Map<String, List<Found>> found = new ConcurrentHashMap<>();
  private volatile @Nullable EmbeddedValueResolver resolver;
  private volatile @Nullable Runnable onGone;
  private volatile boolean closing;

  /** Made by the starter's auto-configuration. */
  public ScheduledMethods() {}

  @Override
  public void setBeanFactory(BeanFactory beanFactory) {
    if (beanFactory instanceof ConfigurableBeanFactory cbf) {
      resolver = new EmbeddedValueResolver(cbf);
    }
  }

  @Override
  public int getOrder() {
    return Ordered.LOWEST_PRECEDENCE;
  }

  /** Every scheduled method found, bean by bean. */
  List<Found> all() {
    List<Found> out = new ArrayList<>();
    for (List<Found> list : found.values()) {
      out.addAll(list);
    }
    return out;
  }

  /** Calls {@code r} when a bean with scheduled methods is destroyed while the app runs. */
  void onGone(Runnable r) {
    onGone = r;
  }

  @Override
  public Object postProcessAfterInitialization(Object bean, String beanName) throws BeansException {
    Class<?> target = AopProxyUtils.ultimateTargetClass(bean);
    Map<Method, Set<Scheduled>> annotated =
        MethodIntrospector.selectMethods(
            target,
            (MethodIntrospector.MetadataLookup<Set<Scheduled>>)
                method -> {
                  Set<Scheduled> s =
                      AnnotatedElementUtils.getMergedRepeatableAnnotations(
                          method, Scheduled.class, Schedules.class);
                  return s.isEmpty() ? null : s;
                });
    if (annotated.isEmpty()) {
      return bean;
    }
    List<Found> list = new ArrayList<>();
    Class<?> user = ClassUtils.getUserClass(target);
    for (Map.Entry<Method, Set<Scheduled>> e : annotated.entrySet()) {
      Method method = e.getKey();
      List<Schedule> schedules = new ArrayList<>();
      for (Scheduled s : e.getValue()) {
        Schedule read = read(s);
        if (read != null) {
          schedules.add(read);
        }
      }
      if (schedules.isEmpty()) {
        continue; // every annotation disabled, as cron = "-" does
      }
      list.add(
          new Found(
              beanName,
              user,
              method,
              List.copyOf(schedules),
              AnnotatedElementUtils.findMergedAnnotation(method, CronwatchJob.class),
              reactive(method),
              locked(method)));
    }
    if (!list.isEmpty()) {
      found.put(beanName, List.copyOf(list));
    }
    return bean;
  }

  @Override
  public boolean requiresDestruction(Object bean) {
    Class<?> user = ClassUtils.getUserClass(AopProxyUtils.ultimateTargetClass(bean));
    return found.values().stream().flatMap(List::stream).anyMatch(f -> f.userClass().equals(user));
  }

  @Override
  public void postProcessBeforeDestruction(Object bean, String beanName) {
    if (found.remove(beanName) == null || closing) {
      return;
    }
    Runnable r = onGone;
    if (r != null) {
      r.run();
    }
  }

  @Override
  public void onApplicationEvent(ContextClosedEvent event) {
    closing = true;
  }

  private String resolve(String value) {
    EmbeddedValueResolver r = resolver;
    String out = r == null ? value : r.resolveStringValue(value);
    return out == null ? "" : out.trim();
  }

  /** One annotation as Spring reads it, or null when it schedules nothing. */
  private @Nullable Schedule read(Scheduled s) {
    TimeUnit unit = s.timeUnit();
    String cron = resolve(s.cron());
    if (!cron.isEmpty()) {
      if (cron.equals(Scheduled.CRON_DISABLED)) {
        return null;
      }
      return new Schedule(Kind.CRON, cron, resolve(s.zone()), 0);
    }
    long rate = s.fixedRate();
    String rateText = resolve(s.fixedRateString());
    if (rate < 0 && !rateText.isEmpty()) {
      rate = millis(rateText, unit);
    } else if (rate >= 0) {
      rate = unit.toMillis(rate);
    }
    if (rate >= 0) {
      return new Schedule(Kind.FIXED_RATE, "", "", rate);
    }
    long delay = s.fixedDelay();
    String delayText = resolve(s.fixedDelayString());
    if (delay < 0 && !delayText.isEmpty()) {
      delay = millis(delayText, unit);
    } else if (delay >= 0) {
      delay = unit.toMillis(delay);
    }
    if (delay >= 0) {
      return new Schedule(Kind.FIXED_DELAY, "", "", delay);
    }
    return new Schedule(Kind.ONCE, "", "", 0);
  }

  /**
   * A duration as Spring reads a {@code fixedRateString}: a number in the annotation's unit, an
   * ISO-8601 duration ({@code PT5M}), or the simple form ({@code 5m}). -1 for text Spring would
   * refuse, which Spring then reports itself.
   */
  static long millis(String text, TimeUnit unit) {
    String t = text.trim();
    try {
      return unit.toMillis(Long.parseLong(t));
    } catch (NumberFormatException e) {
      // Not a plain number.
    }
    try {
      if (t.toUpperCase(Locale.ROOT).startsWith("P")
          || t.toUpperCase(Locale.ROOT).startsWith("-P")) {
        return Duration.parse(t).toMillis();
      }
      Matcher m = SIMPLE.matcher(t.toLowerCase(Locale.ROOT));
      if (m.matches()) {
        long n = Long.parseLong(m.group(1));
        return switch (m.group(2)) {
          case "ns" -> TimeUnit.NANOSECONDS.toMillis(n);
          case "us" -> TimeUnit.MICROSECONDS.toMillis(n);
          case "ms" -> n;
          case "s" -> TimeUnit.SECONDS.toMillis(n);
          case "m" -> TimeUnit.MINUTES.toMillis(n);
          case "h" -> TimeUnit.HOURS.toMillis(n);
          default -> TimeUnit.DAYS.toMillis(n);
        };
      }
    } catch (RuntimeException e) {
      // Refused below.
    }
    return -1;
  }

  /**
   * Whether Spring observes the method around a subscription rather than its work: one returning a
   * Reactive Streams {@code Publisher} (a {@code Mono}, a {@code Flux}) or a Kotlin flow, or a
   * Kotlin {@code suspend} function.
   */
  static boolean reactive(Method method) {
    Class<?>[] params = method.getParameterTypes();
    if (params.length > 0
        && params[params.length - 1].getName().equals("kotlin.coroutines.Continuation")) {
      return true;
    }
    return assignableTo(method.getReturnType(), "org.reactivestreams.Publisher")
        || assignableTo(method.getReturnType(), "kotlinx.coroutines.flow.Flow");
  }

  private static boolean assignableTo(Class<?> type, String name) {
    for (Class<?> c = type; c != null; c = c.getSuperclass()) {
      if (c.getName().equals(name)) {
        return true;
      }
      for (Class<?> i : c.getInterfaces()) {
        if (assignableTo(i, name)) {
          return true;
        }
      }
    }
    return false;
  }

  /** Whether the method carries ShedLock's {@code @SchedulerLock}, found by name. */
  static boolean locked(Method method) {
    for (java.lang.annotation.Annotation a : method.getAnnotations()) {
      if (a.annotationType()
          .getName()
          .equals("net.javacrumbs.shedlock.spring.annotation.SchedulerLock")) {
        return true;
      }
    }
    return false;
  }

  @Override
  public String toString() {
    return "ScheduledMethods[" + found.size() + " beans]";
  }
}
