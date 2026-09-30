package dev.cronwatch;

import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.internal.evaluate.Evaluate.AlertDraft;
import dev.cronwatch.internal.evaluate.Format;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/**
 * Sending alerts: the outbox, channels, triage, and the queue of alerts no channel accepted,
 * retried once per check (the SDK's {@code outbox}, {@code dispatch}, {@code retryUndelivered},
 * {@code recordDelivery}, {@code deliver} and {@code addTriage}).
 */
final class Delivery {
  private final Core core;

  Delivery(Core core) {
    this.core = core;
  }

  /** Alerts written with the state that opened their conditions, and how many the queue let go. */
  record Held(List<Alert> alerts, int dropped) {}

  /**
   * An evaluation as it is written: its drafts composed into alerts and held in the same state
   * ({@code holdAlerts}), so the write that opens a condition also keeps its alerts, and a process
   * that stops before sending them does not lose them. Called inside {@code updateState}, so it
   * only computes.
   */
  Core.Changed<Held> outbox(JobState state, List<AlertDraft> drafts, Definition def, long now) {
    List<Alert> alerts = new ArrayList<>(drafts.size());
    for (AlertDraft draft : drafts) {
      alerts.add(Format.composeAlert(draft, def, now));
    }
    Evaluate.Queued held =
        Evaluate.holdAlerts(state, alerts, core.now() + Evaluate.SEND_LEASE_MS, core.deferDelivery);
    return new Core.Changed<>(held.state(), new Held(alerts, held.dropped()));
  }

  /** Reports alerts let go because a job's queue was full. */
  void reportDropped(String name, int dropped) {
    if (dropped <= 0) {
      return;
    }
    core.report(
        dropped
            + " undelivered alert"
            + (dropped == 1 ? "" : "s")
            + " for "
            + name
            + " dropped: only the newest "
            + Evaluate.MAX_UNDELIVERED
            + " are kept for retry",
        "alert queue for " + name);
  }

  /**
   * Triages and sends each alert the outbox holds (see {@link #outbox}). The state, with the alerts
   * in it, was saved before this, so a slow channel holds up nothing else; afterwards only the
   * delivery fields are written back, onto a fresh read of the state, and the alerts leave {@code
   * sending}. Triage is made here, never stored with the held alert: the write that opens a
   * condition cannot wait for it, and a retry triages an alert that has none. With {@code
   * Deliver.AT_CHECK} the alerts were queued for a check elsewhere instead.
   */
  List<Alert> dispatch(String name, List<Alert> alerts, long now) {
    if (alerts.isEmpty() || core.deferDelivery) {
      return alerts;
    }
    List<Alert> sent = new ArrayList<>();
    List<Alert> delivered = new ArrayList<>();
    List<Alert> failed = new ArrayList<>();
    for (Alert held : alerts) {
      Alert alert = held;
      if (core.triage != null && !alert.type().equals(AlertType.RECOVERED)) {
        alert = addTriage(alert, core.timings.triageMs);
      }
      (deliver(alert) ? delivered : failed).add(alert);
      sent.add(alert);
    }
    recordDelivery(name, delivered, failed, List.of(), now);
    return sent;
  }

  /** The retry budget one check shares across its jobs, in wall-clock milliseconds. */
  static final class Budget {
    long spentMs;
  }

  /**
   * Sends the alerts no channel accepted last time, once each, oldest first. {@code state} is the
   * job's state as this check left it: an alert that no longer describes it is dropped instead.
   * Retries across a check share the retry budget; once it is spent the rest stay queued.
   */
  List<Alert> retryUndelivered(String name, JobState state, long now, Budget budget) {
    List<Alert> pending = state.undelivered() == null ? List.of() : state.undelivered();
    if (pending.isEmpty() || Evaluate.isSilenced(state, now) || core.deferDelivery) {
      return List.of();
    }
    List<Alert> dropped = new ArrayList<>();
    List<Alert> delivered = new ArrayList<>();
    List<Alert> failed = new ArrayList<>();
    List<Alert> fresh = new ArrayList<>();
    for (Alert a : pending) {
      (Evaluate.staleAlert(a, state) ? dropped : fresh).add(a);
    }
    for (Alert a : fresh) {
      long left = core.timings.retryBudgetMs - budget.spentMs;
      if (left <= 0) {
        break;
      }
      long started = System.nanoTime();
      Alert alert = a;
      // An alert queued by a process that delivers at check time, or released from a process that
      // stopped while sending it, was never triaged. One that was tried is not tried again.
      if (core.triage != null
          && !alert.type().equals(AlertType.RECOVERED)
          && !alert.triageTried()) {
        alert = addTriage(alert, Math.min(core.timings.triageMs, left));
      }
      (deliver(alert) ? delivered : failed).add(alert);
      budget.spentMs += Math.max(0, (System.nanoTime() - started) / 1_000_000);
    }
    recordDelivery(name, delivered, failed, dropped, now);
    return delivered;
  }

  /**
   * Marks delivered alerts done, drops stale ones, and keeps failed ones for the next check, taking
   * them all out of {@code sending} ({@code recordSent}). A failed alert replaces its stored copy,
   * so a triage made on this attempt is kept. {@code lastAlertAt} moves only on a delivery. When
   * this write fails, alerts still in {@code sending} are retried once their lease runs out.
   */
  private void recordDelivery(
      String name, List<Alert> delivered, List<Alert> failed, List<Alert> dropped, long now) {
    try {
      Core.Changed<Integer> out =
          core.updateState(
              name,
              previous -> {
                Evaluate.Queued sent =
                    Evaluate.recordSent(
                        Evaluate.normalizeState(previous, name), delivered, failed, dropped, now);
                return new Core.Changed<>(sent.state(), sent.dropped());
              });
      reportDropped(name, out.result());
    } catch (RuntimeException e) {
      core.report(e, "recording alert delivery for " + name);
    }
  }

  /** Sends to every channel at once. True when at least one accepted it, or there are none. */
  boolean deliver(Alert alert) {
    if (core.channels.isEmpty()) {
      return true;
    }
    List<Future<?>> sends = new ArrayList<>();
    for (Channel channel : core.channels) {
      ChannelContext context =
          new ChannelContext(
              e -> core.report(e, "alert channel " + channel.name()), core.transport);
      sends.add(
          core.submit(
              () -> {
                channel.send(alert, context);
                return null;
              }));
    }
    long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(core.timings.channelMs);
    boolean ok = false;
    for (int i = 0; i < sends.size(); i++) {
      Channel channel = core.channels.get(i);
      if (await(sends.get(i), deadline, "alert channel " + channel.name())) {
        ok = true;
      }
    }
    return ok;
  }

  /**
   * Waits for a send until the deadline: true when it went out. A throw is reported; past the
   * deadline the send is cancelled (its thread interrupted) and reported as timed out.
   */
  private boolean await(Future<?> send, long deadline, String where) {
    boolean interrupted = false;
    try {
      while (true) {
        try {
          send.get(Math.max(0, deadline - System.nanoTime()), TimeUnit.NANOSECONDS);
          return true;
        } catch (InterruptedException e) {
          interrupted = true;
        } catch (ExecutionException e) {
          core.report(e.getCause() == null ? e : e.getCause(), where);
          return false;
        } catch (TimeoutException e) {
          send.cancel(true);
          core.report("timed out after " + core.timings.channelMs + "ms", where);
          return false;
        }
      }
    } finally {
      if (interrupted) {
        Thread.currentThread().interrupt();
      }
    }
  }

  /** The alert with triage tried: its diagnosis, or none, so it is tried once per alert. */
  private Alert addTriage(Alert alert, long timeoutMs) {
    String where = "triage for " + alert.job();
    Triage triage = core.triage;
    if (triage == null) {
      return alert.withTriage(null);
    }
    List<Run> recent;
    try {
      recent = Core.call(() -> core.store.listRuns(alert.job(), 5));
    } catch (RuntimeException e) {
      core.report(e, where);
      return alert.withTriage(null);
    }
    Triage.Context context = new Triage.Context(alert, recent, core.transport);
    Future<String> task = core.submit(() -> triage.triage(context));
    long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs);
    boolean interrupted = false;
    try {
      while (true) {
        try {
          String text = task.get(Math.max(0, deadline - System.nanoTime()), TimeUnit.NANOSECONDS);
          return alert.withTriage(text == null || text.isEmpty() ? null : text);
        } catch (InterruptedException e) {
          interrupted = true;
        } catch (ExecutionException e) {
          core.report(e.getCause() == null ? e : e.getCause(), where);
          return alert.withTriage(null);
        } catch (TimeoutException e) {
          task.cancel(true);
          core.report("timed out after " + timeoutMs + "ms", where);
          return alert.withTriage(null);
        }
      }
    } finally {
      if (interrupted) {
        Thread.currentThread().interrupt();
      }
    }
  }
}
