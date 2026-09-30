package dev.cronwatch;

import static dev.cronwatch.Support.MIN;
import static dev.cronwatch.Support.T0;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

import dev.cronwatch.Support.Capture;
import dev.cronwatch.Support.Clock;
import dev.cronwatch.Support.Errors;
import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.store.MemoryStore;
import dev.cronwatch.store.Store;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

/**
 * The SDK's {@code outbox.test.ts}, ported: an alert is written with the state that opens its
 * condition, so a process that dies before sending it does not lose it, and a live sender's alert
 * is sent by no one else.
 */
class OutboxTest {
  /**
   * A store for a process about to die: once {@link #kill} is called, nothing it asks of the store
   * ever completes, as when the process is gone.
   */
  static final class Mortal {
    final Store store;
    private volatile boolean dead;

    Mortal(Store inner) {
      store =
          (Store)
              Proxy.newProxyInstance(
                  Store.class.getClassLoader(),
                  new Class<?>[] {Store.class},
                  (proxy, method, args) -> {
                    if (dead && method.getDeclaringClass() != Object.class) {
                      new CountDownLatch(1).await();
                    }
                    try {
                      return method.invoke(inner, args);
                    } catch (InvocationTargetException e) {
                      throw e.getCause();
                    }
                  });
    }

    void kill() {
      dead = true;
    }
  }

  /** The alerts' types and times and triage, for comparing. */
  private static List<List<Object>> seen(List<Alert> alerts) {
    List<List<Object>> out = new ArrayList<>();
    for (Alert a : alerts) {
      out.add(List.of(a.type().value(), a.at(), String.valueOf(a.triage())));
    }
    return out;
  }

  private static void fail() {
    throw new IllegalStateException("disk full");
  }

  @Test
  void theWriteThatOpensAConditionHoldsItsAlertSoAProcessThatDiesBeforeSendingDoesNotLoseIt()
      throws Exception {
    Clock clock = new Clock();
    MemoryStore shared = new MemoryStore();
    Mortal mortal = new Mortal(shared);
    CountDownLatch triaging = new CountDownLatch(1);
    // The process dies while its triage call is out: no channel was ever called.
    Cronwatch.Builder b =
        Support.builder(clock, new Capture(), new Errors())
            .store(mortal.store)
            .triage(
                context -> {
                  mortal.kill();
                  triaging.countDown();
                  new CountDownLatch(1).await();
                  return null;
                });
    b.timings.triageMs = 3_600_000;
    Cronwatch dying = b.build();
    Support.background(() -> dying.run("nightly", j -> fail()));
    triaging.await();
    JobState state = shared.getState("nightly");
    assertNotNull(state);
    assertEquals(T0, state.openAt(Condition.FAILED));
    List<SendingAlert> sending = state.sending();
    assertNotNull(sending);
    assertEquals(1, sending.size());
    Alert held = sending.get(0).alert();
    assertNotNull(held);
    assertEquals(
        List.of("failed", T0, T0 + Evaluate.SEND_LEASE_MS),
        List.of(held.type().value(), held.at(), sending.get(0).until()));
    assertNull(held.triage(), "triage is made at send time, never stored here");
    assertEquals(false, held.toValue().has("triage"));
    assertEquals(List.of(), state.undelivered());

    // Another process's checks leave it alone while its sender's lease runs.
    Capture sent = new Capture();
    try (Cronwatch server =
        Support.builder(clock, sent, new Errors())
            .store(shared)
            .triage(context -> "The disk is full.")
            .build()) {
      clock.advance(MIN);
      server.check();
      assertEquals(List.of(), sent.types());

      // Once it has run out, the next check sends it, triaged, once.
      clock.set(T0 + Evaluate.SEND_LEASE_MS + 1);
      CheckResult result = server.check();
      assertEquals(List.of("failed"), seen(result.alerts()).stream().map(a -> a.get(0)).toList());
      assertEquals(List.of(List.of("failed", T0, "The disk is full.")), seen(sent.alerts));
      JobState after = shared.getState("nightly");
      assertNotNull(after);
      assertNull(after.sending(), "the key goes once nothing is being sent");
      assertEquals(false, after.toValue().has("sending"));
      assertEquals(List.of(), after.undelivered());
      server.check();
      assertThrows(IllegalStateException.class, () -> server.run("nightly", j -> fail()));
      assertEquals(List.of("failed"), sent.types(), "the condition still alerts once");
    }
  }

  @Test
  void anAlertAChannelTookJustBeforeItsProcessDiedIsSentAgainAfterTheLease() throws Exception {
    Clock clock = new Clock();
    MemoryStore shared = new MemoryStore();
    Mortal mortal = new Mortal(shared);
    Capture first = new Capture();
    CountDownLatch taken = new CountDownLatch(1);
    // Accepted, then the process is gone before it records that.
    Channel accepting =
        new Channel() {
          @Override
          public String name() {
            return "first";
          }

          @Override
          public void send(Alert alert, ChannelContext context) {
            first.send(alert, context);
            mortal.kill();
            taken.countDown();
          }
        };
    Cronwatch dying =
        Support.builder(clock, new Capture(), new Errors())
            .alerts(List.of(accepting))
            .store(mortal.store)
            .build();
    Support.background(() -> dying.run("nightly", j -> fail()));
    taken.await();
    assertEquals(List.of("failed"), first.types());
    Capture sent = new Capture();
    try (Cronwatch server = Support.builder(clock, sent, new Errors()).store(shared).build()) {
      clock.set(T0 + Evaluate.SEND_LEASE_MS + 1);
      server.check();
      assertEquals(
          List.of("failed"),
          sent.types(),
          "sent a second time: the one duplicate a crash can cause");
    }
  }

  @Test
  void whileAnAlertIsBeingSentNoCheckAnywhereSendsItToo() throws Exception {
    Clock clock = new Clock();
    MemoryStore shared = new MemoryStore();
    CountDownLatch gate = new CountDownLatch(1);
    CountDownLatch sending = new CountDownLatch(1);
    List<Alert> sent = new CopyOnWriteArrayList<>();
    Channel held =
        new Channel() {
          @Override
          public String name() {
            return "held";
          }

          @Override
          public void send(Alert alert, ChannelContext context) throws InterruptedException {
            sending.countDown();
            gate.await();
            sent.add(alert);
          }
        };
    Capture other = new Capture();
    try (Cronwatch worker =
            Support.builder(clock, new Capture(), new Errors())
                .alerts(List.of(held))
                .store(shared)
                .build();
        Cronwatch server = Support.builder(clock, other, new Errors()).store(shared).build()) {
      Thread run = Support.background(() -> worker.run("nightly", j -> fail()));
      sending.await();
      clock.advance(MIN);
      server.check();
      // The sending process's own check, too.
      worker.check();
      gate.countDown();
      run.join();
      assertEquals(List.of("failed"), sent.stream().map(a -> a.type().value()).toList());
      assertEquals(List.of(), other.types());
      JobState state = shared.getState("nightly");
      assertNotNull(state);
      assertNull(state.sending());
      assertEquals(List.of(), state.undelivered());
      assertEquals(T0, state.lastAlertAt(), "the time the run was judged, as before");
      clock.set(T0 + Evaluate.SEND_LEASE_MS + MIN);
      server.check();
      worker.check();
      assertEquals(List.of(), other.types());
      assertEquals(List.of("failed"), sent.stream().map(a -> a.type().value()).toList());
    }
  }

  @Test
  void anAlertNoChannelTookMovesFromTheOutboxToTheRetryQueueWithItsTriage() throws Exception {
    Clock clock = new Clock();
    MemoryStore shared = new MemoryStore();
    Channel down =
        new Channel() {
          @Override
          public String name() {
            return "down";
          }

          @Override
          public void send(Alert alert, ChannelContext context) {
            throw new IllegalStateException("down");
          }
        };
    try (Cronwatch cw =
        Support.builder(clock, new Capture(), new Errors())
            .alerts(List.of(down))
            .store(shared)
            .triage(context -> "Look at the disk.")
            .build()) {
      assertThrows(IllegalStateException.class, () -> cw.run("nightly", j -> fail()));
      JobState state = shared.getState("nightly");
      assertNotNull(state);
      assertNull(state.sending());
      assertEquals(List.of(List.of("failed", T0, "Look at the disk.")), seen(state.undelivered()));
    }
  }

  @Test
  void aProcessThatQueuesForACheckElsewhereWritesItsAlertsWithTheStateThatOpensTheCondition()
      throws Exception {
    Clock clock = new Clock();
    MemoryStore shared = new MemoryStore();
    AtomicInteger writes = new AtomicInteger();
    Store counting =
        (Store)
            Proxy.newProxyInstance(
                Store.class.getClassLoader(),
                new Class<?>[] {Store.class},
                (proxy, method, args) -> {
                  if (method.getName().equals("compareAndSetState")) {
                    writes.incrementAndGet();
                  }
                  try {
                    return method.invoke(shared, args);
                  } catch (InvocationTargetException e) {
                    throw e.getCause();
                  }
                });
    try (Cronwatch recorder =
        Support.builder(clock, new Capture(), new Errors())
            .store(counting)
            .deliver(Deliver.AT_CHECK)
            .build()) {
      assertThrows(IllegalStateException.class, () -> recorder.run("backup", j -> fail()));
      JobState state = shared.getState("backup");
      assertNotNull(state);
      assertEquals(
          List.of("failed"), state.undelivered().stream().map(a -> a.type().value()).toList());
      assertNull(state.sending());
      assertEquals(1, writes.get(), "one write: the failure and its alert together");
    }
  }
}
