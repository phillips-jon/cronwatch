package dev.cronwatch;

import static org.junit.jupiter.api.Assertions.assertTrue;

import dev.cronwatch.internal.js.Js;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BooleanSupplier;
import org.jspecify.annotations.Nullable;

/**
 * What the ports of the SDK's client tests share (its {@code test/helpers.ts}): a clock the tests
 * drive, a channel that keeps what it is sent, an error collector, and a store wrapped so a test
 * can break its methods, slow its state reads, or take its optional methods away.
 */
final class Support {
  private Support() {}

  /** Monday 2026-01-05 09:30:00 UTC. */
  static final long T0 = Js.dateUtc(2026, 0, 5, 9, 30, 0, 0);

  static final long MIN = 60_000;
  static final long HOUR = 3_600_000;

  /** A clock the test sets and advances. */
  static final class Clock {
    private final AtomicLong now;

    Clock() {
      this(T0);
    }

    Clock(long start) {
      now = new AtomicLong(start);
    }

    long now() {
      return now.get();
    }

    void set(long t) {
      now.set(t);
    }

    long advance(long ms) {
      return now.addAndGet(ms);
    }
  }

  /** A channel that keeps every alert it is sent. */
  static final class Capture implements Channel {
    final List<Alert> alerts = new CopyOnWriteArrayList<>();

    @Override
    public String name() {
      return "capture";
    }

    @Override
    public void send(Alert alert, ChannelContext context) {
      alerts.add(alert);
    }

    List<String> types() {
      List<String> out = new ArrayList<>();
      for (Alert a : alerts) {
        out.add(a.type().value());
      }
      return out;
    }
  }

  /** The errors a client reported, with where each happened. */
  static final class Errors implements ErrorHandler {
    record Entry(String where, Throwable error) {}

    final List<Entry> entries = new CopyOnWriteArrayList<>();

    @Override
    public void handle(String where, Throwable error) {
      entries.add(new Entry(where, error));
    }

    List<String> wheres() {
      List<String> out = new ArrayList<>();
      for (Entry e : entries) {
        out.add(e.where());
      }
      return out;
    }

    List<String> messages() {
      List<String> out = new ArrayList<>();
      for (Entry e : entries) {
        out.add(String.valueOf(e.error().getMessage()));
      }
      return out;
    }
  }

  /** A test's client and what it watches. */
  record Made(Cronwatch cw, Clock clock, Capture alerts, Errors errors) {}

  /** A builder with the test clock, a capturing channel, errors collected and no hook. */
  static Cronwatch.Builder builder(Clock clock, Capture alerts, Errors errors) {
    return Cronwatch.builder()
        .clock(clock::now)
        .alert(alerts)
        .noCronSecret()
        .onError(errors)
        .noShutdownHook();
  }

  /** The SDK tests' {@code make()}. */
  static Made make() {
    return make(b -> {});
  }

  /** {@code make()} with more options. */
  static Made make(java.util.function.Consumer<Cronwatch.Builder> options) {
    Clock clock = new Clock();
    Capture alerts = new Capture();
    Errors errors = new Errors();
    Cronwatch.Builder b = builder(clock, alerts, errors);
    options.accept(b);
    return new Made(b.build(), clock, alerts, errors);
  }

  /** The text up to its first newline. */
  static String firstLine(String text) {
    int n = text.indexOf('\n');
    return n < 0 ? text : text.substring(0, n);
  }

  /** A body that may throw anything, for {@link #background}. */
  @FunctionalInterface
  interface Body {
    void run() throws Exception;
  }

  /**
   * Runs {@code body} on a virtual thread of the test's, as a promise the SDK tests leave pending;
   * what it throws is the run's business, recorded by the client, so it is dropped here.
   */
  static Thread background(Body body) {
    return Thread.ofVirtual()
        .start(
            () -> {
              try {
                body.run();
              } catch (Exception e) {
                // The client recorded it.
              }
            });
  }

  /**
   * Waits up to ten seconds for {@code condition}, polling, and fails with {@code what} if it never
   * holds.
   */
  static void await(String what, BooleanSupplier condition) throws InterruptedException {
    long deadline = System.nanoTime() + 10_000_000_000L;
    while (!condition.getAsBoolean()) {
      if (System.nanoTime() > deadline) {
        assertTrue(condition.getAsBoolean(), "waited ten seconds for: " + what);
        return;
      }
      Thread.sleep(10);
    }
  }

  /**
   * An answer of the JDK's HTTP client with a status and nothing else, the Java counterpart of the
   * SDK tests' {@code new Response("bad", { status: 503 })}. Made through a proxy, since the module
   * under test does not read {@code java.net.http}; the client finds it by name.
   */
  @SuppressWarnings("ReferenceEquality") // a proxy is equal only to itself
  static Object httpResponse(int status) throws ClassNotFoundException {
    Class<?> type = Class.forName("java.net.http.HttpResponse");
    return java.lang.reflect.Proxy.newProxyInstance(
        Support.class.getClassLoader(),
        new Class<?>[] {type},
        (proxy, method, args) ->
            switch (method.getName()) {
              case "statusCode" -> status;
              case "toString" -> "HttpResponse " + status;
              case "hashCode" -> status;
              case "equals" -> proxy == args[0];
              default -> null;
            });
  }

  /** How the wrapped store answers {@code compareAndSetState}. */
  enum Cas {
    /** As the store underneath does. */
    NORMAL,
    /** As a store without it: unsupported, so the client writes plainly. */
    MISSING,
    /** Always refused, as if another process wrote between every read and write. */
    REFUSED
  }

  /**
   * A store over another whose methods throw while named in {@link #broken}, whose state reads take
   * {@code readDelayMs}, whose {@code updateRunIf} can be held at a gate, whose first {@code
   * upsertJob} can be held at one, and whose {@code compareAndSetState} can be missing or refuse.
   */
  static final class Wrapped implements Store {
    final Store inner;
    final Set<String> broken = ConcurrentHashMap.newKeySet();
    volatile long readDelayMs;
    volatile Cas cas = Cas.NORMAL;
    volatile int initFailures;
    final AtomicLong inits = new AtomicLong();

    /** Counted down when {@code updateRunIf} is entered, when set. */
    volatile @Nullable CountDownLatch entered;

    /** Waited on inside {@code updateRunIf}, when set. */
    volatile @Nullable CountDownLatch gate;

    /** Run once {@code insertRun} has written the row, before it returns, when set. */
    volatile @Nullable Runnable afterInsert;

    /** Waited on inside the first {@code upsertJob} after it is set, and in no later one. */
    final AtomicReference<@Nullable CountDownLatch> upsertGate = new AtomicReference<>();

    /** Counted down when the {@code upsertJob} that waits on {@link #upsertGate} is entered. */
    final CountDownLatch upsertEntered = new CountDownLatch(1);

    /**
     * Waited on once the first {@code upsertJob} after it is set has written, and in no later one.
     */
    final AtomicReference<@Nullable CountDownLatch> upsertAfterGate = new AtomicReference<>();

    /**
     * Counted down when the {@code upsertJob} that waits on {@link #upsertAfterGate} has written.
     */
    final CountDownLatch upsertWritten = new CountDownLatch(1);

    Wrapped(Store inner) {
      this.inner = inner;
    }

    Wrapped() {
      this(new MemoryStore());
    }

    private void check(String method) {
      if (broken.contains(method)) {
        throw new IllegalStateException("store down: " + method);
      }
    }

    @Override
    public void init() throws Exception {
      check("init");
      if (inits.incrementAndGet() <= initFailures) {
        throw new IllegalStateException("not yet");
      }
      inner.init();
    }

    @Override
    public void upsertJob(Definition definition, long now) throws Exception {
      check("upsertJob");
      CountDownLatch held = upsertGate.getAndSet(null);
      if (held != null) {
        upsertEntered.countDown();
        held.await();
      }
      inner.upsertJob(definition, now);
      CountDownLatch after = upsertAfterGate.getAndSet(null);
      if (after != null) {
        upsertWritten.countDown();
        after.await();
      }
    }

    @Override
    public @Nullable StoredJob getJob(String name) throws Exception {
      check("getJob");
      return inner.getJob(name);
    }

    @Override
    public List<StoredJob> listJobs() throws Exception {
      check("listJobs");
      return inner.listJobs();
    }

    @Override
    public void deleteJob(String name) throws Exception {
      check("deleteJob");
      inner.deleteJob(name);
    }

    @Override
    public void insertRun(Run run) throws Exception {
      check("insertRun");
      inner.insertRun(run);
      Runnable after = afterInsert;
      if (after != null) {
        after.run();
      }
    }

    @Override
    public void updateRun(Run run) throws Exception {
      check("updateRun");
      inner.updateRun(run);
    }

    @Override
    public boolean updateRunIf(Run run, List<RunStatus> from) throws Exception {
      check("updateRunIf");
      CountDownLatch e = entered;
      if (e != null) {
        e.countDown();
      }
      CountDownLatch g = gate;
      if (g != null) {
        g.await();
      }
      return inner.updateRunIf(run, from);
    }

    @Override
    public @Nullable Run getRun(String id) throws Exception {
      check("getRun");
      return inner.getRun(id);
    }

    @Override
    public List<Run> listRuns(String job, int limit) throws Exception {
      check("listRuns");
      return inner.listRuns(job, limit);
    }

    @Override
    public List<Run> runningRuns() throws Exception {
      check("runningRuns");
      return inner.runningRuns();
    }

    @Override
    public @Nullable JobState getState(String job) throws Exception {
      check("getState");
      JobState s = inner.getState(job);
      if (readDelayMs > 0) {
        Thread.sleep(readDelayMs);
      }
      return s;
    }

    @Override
    public void setState(JobState state) throws Exception {
      check("setState");
      inner.setState(state);
    }

    @Override
    public boolean compareAndSetState(JobState state, long expected) throws Exception {
      check("compareAndSetState");
      return switch (cas) {
        case NORMAL -> inner.compareAndSetState(state, expected);
        case MISSING -> throw new UnsupportedOperationException("compareAndSetState");
        case REFUSED -> false;
      };
    }

    @Override
    public void close() throws Exception {
      inner.close();
    }

    @Override
    public long prune(long before) throws Exception {
      check("prune");
      return inner.prune(before);
    }
  }
}
