package dev.cronwatch;

import dev.cronwatch.internal.evaluate.Evaluate;
import dev.cronwatch.internal.evaluate.Evaluate.AlertDraft;
import dev.cronwatch.internal.evaluate.Format;
import dev.cronwatch.internal.evaluate.MutableState;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/**
 * Sending alerts: channels, triage, and the queue of alerts no channel accepted, retried once per
 * check (the SDK's {@code dispatch}, {@code retryUndelivered}, {@code recordDelivery}, {@code
 * deliver} and {@code addTriage}).
 */
final class Delivery {
  /** Undelivered alerts kept per job for retry; the oldest go first. */
  static final int MAX_UNDELIVERED = 20;

  private final Core core;

  Delivery(Core core) {
    this.core = core;
  }

  /** Identifies an alert across retries. */
  private static String alertKey(Alert a) {
    Run run = a.run();
    return a.type().value() + "|" + a.at() + "|" + (run == null ? "" : run.id());
  }

  /**
   * Composes, triages and sends each draft. The state was saved before this, so a slow channel
   * holds up nothing else; afterwards only the delivery fields are written back, onto a fresh read
   * of the state.
   */
  List<Alert> dispatch(List<AlertDraft> drafts, Definition def, long now) {
    List<Alert> composed = new ArrayList<>();
    if (drafts.isEmpty()) {
      return composed;
    }
    List<Alert> delivered = new ArrayList<>();
    List<Alert> failed = new ArrayList<>();
    for (AlertDraft draft : drafts) {
      Alert alert = Format.composeAlert(draft, def, now);
      if (core.deferDelivery) {
        failed.add(alert);
      } else {
        if (core.triage != null && !alert.type().equals(AlertType.RECOVERED)) {
          alert = addTriage(alert, core.timings.triageMs);
        }
        (deliver(alert) ? delivered : failed).add(alert);
      }
      composed.add(alert);
    }
    recordDelivery(def.name(), delivered, failed, List.of(), now);
    return composed;
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
      // An alert queued by a process that delivers at check time was never triaged. One that was
      // tried is not tried again.
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
   * Marks delivered alerts done, drops stale ones, and keeps failed ones for the next check. A
   * failed alert replaces its stored copy, so a triage made on this attempt is kept. {@code
   * lastAlertAt} moves only on a delivery.
   */
  private void recordDelivery(
      String name, List<Alert> delivered, List<Alert> failed, List<Alert> dropped, long now) {
    try {
      Core.Changed<Integer> out =
          core.updateState(
              name,
              previous -> {
                MutableState state = MutableState.of(Evaluate.normalizeState(previous, name));
                Set<String> done = new HashSet<>();
                for (Alert a : delivered) {
                  done.add(alertKey(a));
                }
                for (Alert a : dropped) {
                  done.add(alertKey(a));
                }
                Map<String, Alert> retried = new HashMap<>();
                for (Alert a : failed) {
                  retried.put(alertKey(a), a);
                }
                List<Alert> kept = new ArrayList<>();
                Set<String> known = new HashSet<>();
                for (Alert a : state.queued()) {
                  String key = alertKey(a);
                  if (done.contains(key)) {
                    continue;
                  }
                  kept.add(retried.getOrDefault(key, a));
                  known.add(key);
                }
                for (Alert a : failed) {
                  if (!known.contains(alertKey(a))) {
                    kept.add(a);
                  }
                }
                int trimmed = Math.max(0, kept.size() - MAX_UNDELIVERED);
                state.undelivered = new ArrayList<>(kept.subList(trimmed, kept.size()));
                if (!delivered.isEmpty()) {
                  state.lastAlertAt = now;
                }
                return new Core.Changed<>(state.toState(), trimmed);
              });
      int trimmed = out.result();
      if (trimmed > 0) {
        core.report(
            trimmed
                + " undelivered alert"
                + (trimmed == 1 ? "" : "s")
                + " for "
                + name
                + " dropped: only the newest "
                + MAX_UNDELIVERED
                + " are kept for retry",
            "alert queue for " + name);
      }
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
          new ChannelContext(e -> core.report(e, "alert channel " + channel.name()));
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
    Triage.Context context = new Triage.Context(alert, recent);
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
