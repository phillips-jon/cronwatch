package dev.cronwatch.spring;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.Job;
import dev.cronwatch.JobOptions;
import dev.cronwatch.bridge.Bridge;
import dev.cronwatch.bridge.Entry;
import dev.cronwatch.bridge.FireTimes;
import dev.cronwatch.bridge.ScheduleException;
import dev.cronwatch.bridge.Watch;
import dev.cronwatch.json.Json;
import io.micrometer.observation.ObservationRegistry;
import java.lang.reflect.Method;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.locks.ReentrantLock;
import org.jspecify.annotations.Nullable;
import org.springframework.beans.factory.DisposableBean;
import org.springframework.beans.factory.SmartInitializingSingleton;
import org.springframework.core.Ordered;
import org.springframework.scheduling.annotation.SchedulingConfigurer;
import org.springframework.scheduling.config.ScheduledTaskRegistrar;
import org.springframework.scheduling.support.CronExpression;
import org.springframework.util.StringUtils;

/**
 * The {@code @Scheduled} integration: the methods {@link ScheduledMethods} found declared as jobs
 * once every bean is made, and a {@link ScheduledRuns} handler given to Spring's scheduling through
 * the observation registry it reports each invocation to, from this {@link SchedulingConfigurer}.
 *
 * <p>A job is named {@code SimpleClassName.method} after the bean's own class (not its proxy's),
 * the fully qualified name when two classes' simple names would give one name,
 * {@code @CronwatchJob(name = ...)} or {@code cronwatch.jobs[<name>].name} to name it. A cron is
 * Spring's six-field expression in the annotation's zone, else the JVM's, checked against Spring's
 * own {@link CronExpression} and watched without a schedule when the two differ; a {@code
 * fixedRate} or a {@code fixedDelay} is {@code every <interval>}. Jobs are tagged {@code
 * spring-scheduled} and {@code spring-scheduled:<app>}.
 */
public final class CronwatchScheduling
    implements SmartInitializingSingleton, SchedulingConfigurer, Ordered, DisposableBean {
  /** The tag every job this integration declares carries. */
  public static final String TAG = "spring-scheduled";

  private static final String SCHEDULER = "Spring";

  /**
   * What an invocation's run needs of its method: the job's name, its options for a fallback, and
   * whether it is reactive (never a run) or under a ShedLock lock.
   */
  record Target(String name, JobOptions options, boolean reactive, boolean locked) {}

  private final Cronwatch cw;
  private final ScheduledMethods methods;
  private final CronwatchProperties properties;
  private final @Nullable ObservationRegistry appRegistry;
  private final Watch watch;
  private final ScheduledRuns runs;
  private final ReentrantLock lock = new ReentrantLock();
  private final Set<ObservationRegistry> given = Collections.newSetFromMap(new IdentityHashMap<>());
  private volatile Map<String, Target> targets = Map.of();

  CronwatchScheduling(
      Cronwatch cw,
      ScheduledMethods methods,
      CronwatchProperties properties,
      String app,
      @Nullable ObservationRegistry appRegistry,
      boolean shedLock) {
    this.cw = cw;
    this.methods = methods;
    this.properties = properties;
    this.appRegistry = appRegistry;
    this.watch = new Watch(cw, TAG, app, SCHEDULER);
    this.runs = new ScheduledRuns(this, shedLock);
  }

  Cronwatch client() {
    return cw;
  }

  ScheduledRuns handler() {
    return runs;
  }

  String appSlug() {
    return watch.appSlug();
  }

  /** The watch that declares the jobs, for tests and a clean exit. */
  public Watch watchOfJobs() {
    return watch;
  }

  @Override
  public int getOrder() {
    return Ordered.LOWEST_PRECEDENCE;
  }

  @Override
  public void afterSingletonsInstantiated() {
    methods.onGone(this::declare);
    declare();
  }

  /**
   * Gives Spring's scheduling a registry CronWatch's handler is in: the one an earlier configurer
   * set, or the app's, when it has handlers of its own (they are still called), else one of the
   * starter's holding only CronWatch's handler, so an app without observability gets no new
   * observations anywhere else.
   */
  @Override
  public void configureTasks(ScheduledTaskRegistrar registrar) {
    ObservationRegistry current = registrar.getObservationRegistry();
    ObservationRegistry chosen;
    if (current != null && !current.isNoop()) {
      chosen = current;
    } else if (appRegistry != null && !appRegistry.isNoop()) {
      chosen = appRegistry;
    } else {
      chosen = ObservationRegistry.create();
    }
    lock.lock();
    try {
      if (given.add(chosen)) {
        chosen.observationConfig().observationHandler(runs);
      }
      // The app's registry gets the handler too, so a configurer that sets it after this one
      // (Spring Boot's actuator) keeps the runs.
      if (appRegistry != null && !appRegistry.isNoop() && given.add(appRegistry)) {
        appRegistry.observationConfig().observationHandler(runs);
      }
    } finally {
      lock.unlock();
    }
    registrar.setObservationRegistry(chosen);
  }

  /** Stops recording runs; the jobs stay declared. */
  @Override
  public void destroy() {
    runs.close();
  }

  // ---- declaring

  private static String key(Class<?> type, String method) {
    return type.getName() + "#" + method;
  }

  /** The target of an invocation Spring observed, or null for a method this did not find. */
  @Nullable Target target(Class<?> targetClass, Method method) {
    Map<String, Target> t = targets;
    Target found = t.get(key(targetClass, method.getName()));
    if (found != null) {
      return found;
    }
    // A JDK proxy's class, or a subclass: the declaring class and its subclasses were keyed.
    for (Class<?> c = method.getDeclaringClass(); c != null; c = c.getSuperclass()) {
      found = t.get(key(c, method.getName()));
      if (found != null) {
        return found;
      }
    }
    for (ScheduledMethods.Found f : methods.all()) {
      if (f.method().getName().equals(method.getName())
          && (method.getDeclaringClass().isAssignableFrom(f.userClass())
              || f.userClass().isAssignableFrom(targetClass))) {
        return t.get(key(f.userClass(), f.method().getName()));
      }
    }
    return null;
  }

  /** The job an invocation of {@code target} is a run of, declared on first sight if need be. */
  @Nullable Job job(Target target) {
    Job job = watch.job(target.name());
    return job != null ? job : watch.fallback(target.name(), target.options());
  }

  /** A method's job name before any rename: its class's simple name, or its full name. */
  private static String baseName(Class<?> type, Method method, boolean full) {
    String cls = full ? type.getName().replace('$', '.') : type.getSimpleName();
    if (cls.isEmpty()) {
      cls = type.getName().replace('$', '.');
    }
    return cls + "." + method.getName();
  }

  /**
   * Declares every scheduled method found as a job, and again without its schedule a job whose
   * methods are all gone (a bean destroyed while the app runs). One method's schedules are entries
   * of one job, so a method with several is a job without a schedule, as the bridge has it.
   */
  void declare() {
    lock.lock();
    try {
      List<ScheduledMethods.Found> all = methods.all();
      Map<String, Set<Class<?>>> bySimple = new HashMap<>();
      for (ScheduledMethods.Found f : all) {
        bySimple
            .computeIfAbsent(baseName(f.userClass(), f.method(), false), k -> new HashSet<>())
            .add(f.userClass());
      }
      Map<String, Target> made = new HashMap<>();
      List<Entry> entries = new ArrayList<>();
      long now = cw.now();
      for (ScheduledMethods.Found f : all) {
        String simple = baseName(f.userClass(), f.method(), false);
        String name =
            bySimple.get(simple).size() > 1 ? baseName(f.userClass(), f.method(), true) : simple;
        CronwatchJob annotation = f.job();
        if (annotation != null && !annotation.name().isEmpty()) {
          name = annotation.name();
        }
        CronwatchProperties.JobProperties props = properties.getJobs().get(name);
        if (props != null && props.getName() != null && !props.getName().isBlank()) {
          name = props.getName().trim();
        }
        String label = "@Scheduled method " + Json.quote(name);
        if (!Bridge.validName(name)) {
          watch.reportOnce(
              "cronwatch: "
                  + label
                  + " is not a CronWatch job name (1 to 120 letters, digits, \".\", \"_\", \":\""
                  + " or \"-\"), so it is not watched; name it with @CronwatchJob(name = ...)",
              "declaring " + label);
          continue;
        }
        JobOptions options = options(annotation, props);
        made.put(
            key(f.userClass(), f.method().getName()),
            new Target(name, options, f.reactive(), f.locked()));
        if (f.reactive()) {
          watch.reportOnce(
              "cronwatch: "
                  + label
                  + " returns "
                  + f.method().getReturnType().getSimpleName()
                  + " or suspends, which Spring observes around its subscription rather than its"
                  + " work, so its runs are not recorded and it is watched without a schedule",
              "declaring " + label);
          entries.add(new Entry(name, label, "", "", null, JobOptions.builder(), options.copy()));
          continue;
        }
        for (ScheduledMethods.Schedule s : f.schedules()) {
          entries.add(entry(name, label, s, options, now));
        }
      }
      targets = Map.copyOf(made);
      watch.declare(entries);
    } finally {
      lock.unlock();
    }
  }

  /** The options {@code @CronwatchJob} and {@code cronwatch.jobs[<name>]} give, in that order. */
  private static JobOptions options(
      @Nullable CronwatchJob a, CronwatchProperties.@Nullable JobProperties p) {
    JobOptions o = JobOptions.builder();
    if (a != null) {
      if (!a.description().isEmpty()) {
        o.description(a.description());
      }
      if (!a.grace().isEmpty()) {
        o.grace(a.grace());
      }
      if (!a.timeout().isEmpty()) {
        o.timeout(a.timeout());
      }
      if (!a.maxDuration().isEmpty()) {
        o.maxDuration(a.maxDuration());
      }
      if (!a.expect().isEmpty()) {
        o.expect(a.expect());
      }
      if (a.tags().length > 0) {
        o.tags(a.tags());
      }
      if (a.failuresBeforeAlert() > 0) {
        o.failuresBeforeAlert(a.failuresBeforeAlert());
      }
    }
    if (p != null) {
      if (p.getDescription() != null) {
        o.description(p.getDescription());
      }
      if (p.getGrace() != null) {
        o.grace(p.getGrace());
      }
      if (p.getTimeout() != null) {
        o.timeout(p.getTimeout());
      }
      if (p.getMaxDuration() != null) {
        o.maxDuration(p.getMaxDuration());
      }
      if (p.getExpect() != null) {
        o.expect(p.getExpect());
      }
      if (!p.getTags().isEmpty()) {
        o.tags(p.getTags());
      }
      if (p.getFailuresBeforeAlert() != null) {
        o.failuresBeforeAlert(p.getFailuresBeforeAlert());
      }
    }
    return o;
  }

  private Entry entry(
      String name, String label, ScheduledMethods.Schedule s, JobOptions options, long now) {
    String schedule = "";
    String zone = "";
    String problem = null;
    switch (s.kind()) {
      case CRON -> {
        try {
          check(label, s.cron(), s.zone(), now);
          schedule = s.cron();
          zone = s.zone();
        } catch (ScheduleException e) {
          problem = e.getMessage();
        }
      }
      case FIXED_RATE, FIXED_DELAY -> {
        if (s.millis() < 1000) {
          problem =
              "cronwatch: "
                  + label
                  + " runs every "
                  + s.millis()
                  + "ms, more often than CronWatch's shortest schedule of one second, so it is"
                  + " watched without a schedule";
        } else {
          schedule = Bridge.everyText(Duration.ofMillis(s.millis()));
        }
      }
      case ONCE -> {
        // A method run once after a delay has no schedule to keep.
      }
    }
    return new Entry(name, label, schedule, zone, problem, JobOptions.builder(), options.copy());
  }

  /**
   * Checks a {@code @Scheduled} cron against Spring's own fire times in its zone, as CronWatch
   * would read it in the same zone.
   */
  private static void check(String label, String cron, String zone, long now)
      throws ScheduleException {
    CronExpression spring;
    ZoneId tz;
    try {
      spring = CronExpression.parse(cron);
      tz =
          zone.isEmpty()
              ? ZoneId.systemDefault()
              : StringUtils.parseTimeZoneString(zone).toZoneId();
    } catch (IllegalArgumentException e) {
      throw new ScheduleException(
          "cronwatch: "
              + label
              + " is "
              + Json.quote(cron)
              + ", which Spring cannot read: "
              + e.getMessage());
    }
    FireTimes fires =
        FireTimes.walking(
            at -> {
              var next = spring.next(Instant.ofEpochMilli(at).atZone(tz));
              return next == null ? null : next.toInstant().toEpochMilli();
            },
            SCHEDULER);
    Bridge.checkFires(fires, cron, zone, "cronwatch: " + label, SCHEDULER, daily(cron), now);
  }

  /** A cron that names no day or month, which meets every clock change of one kind alike. */
  private static boolean daily(String cron) {
    String c = cron.trim();
    if (c.startsWith("@")) {
      return c.equals("@daily") || c.equals("@midnight") || c.equals("@hourly");
    }
    String[] f = c.split("\\s+", -1);
    return f.length == 6 && any(f[3]) && any(f[4]) && any(f[5]);
  }

  private static boolean any(String field) {
    return field.equals("*") || field.equals("?");
  }

  /**
   * Declares the methods found as they are now, waits for the declarations to be written, and
   * declares again without its schedule each job of this app's the store holds with a schedule no
   * method here has. The starter's check runs it before each check.
   */
  public void sync() {
    declare();
    watch.settle(Bridge.SYNC_TIMEOUT);
    watch.unschedule();
  }

  @Override
  public String toString() {
    return "CronwatchScheduling[" + watch.appTag() + "]";
  }
}
