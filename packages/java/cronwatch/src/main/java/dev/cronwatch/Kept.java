package dev.cronwatch;

import dev.cronwatch.internal.js.Js;
import dev.cronwatch.json.JsObject;
import java.lang.ref.Reference;
import java.lang.ref.ReferenceQueue;
import java.lang.ref.WeakReference;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import org.jspecify.annotations.Nullable;

/**
 * The JSON a queued alert or an outbox entry was read from, held beside the record read from it (by
 * identity, weakly), so the fields a newer writer added are written back and sent with a retry, as
 * the SDK carries queued alerts as plain objects. A record has no field of its own beyond its
 * components, and a component would change its constructor, so the JSON is kept here.
 */
final class Kept {
  private static final ReferenceQueue<Object> QUEUE = new ReferenceQueue<>();
  private static final Map<Key, JsObject> HELD = new HashMap<>();

  /** The alert types this release reads the details of. */
  static final Set<String> KNOWN_TYPES =
      Set.of("missed", "failed", "stuck", "slow", "over_budget", "recovered");

  private Kept() {}

  private static final class Key extends WeakReference<Object> {
    private final int hash;

    Key(Object owner, @Nullable ReferenceQueue<Object> queue) {
      super(owner, queue);
      this.hash = System.identityHashCode(owner);
    }

    @Override
    public int hashCode() {
      return hash;
    }

    @Override
    public boolean equals(@Nullable Object other) {
      if (this == other) {
        return true;
      }
      if (!(other instanceof Key k)) {
        return false;
      }
      Object mine = get();
      return mine != null && k.refersTo(mine);
    }
  }

  private static void purge() {
    for (Reference<?> r = QUEUE.poll(); r != null; r = QUEUE.poll()) {
      HELD.remove(r);
    }
  }

  /** Holds {@code raw} (a copy) for {@code owner}. */
  static synchronized void put(Object owner, JsObject raw) {
    purge();
    HELD.put(new Key(owner, QUEUE), raw.copy());
  }

  /** What {@code owner} was read from, or null for one made in code. */
  static synchronized @Nullable JsObject get(Object owner) {
    purge();
    return HELD.get(new Key(owner, null));
  }

  /**
   * {@code written} with every key of {@code raw} it does not have added after its own, in their
   * stored order.
   */
  static JsObject withUnknown(JsObject written, @Nullable JsObject raw) {
    if (raw == null) {
      return written;
    }
    for (Map.Entry<String, @Nullable Object> e : raw.entries()) {
      if (!written.has(e.getKey())) {
        written.set(e.getKey(), Js.copyJson(e.getValue()));
      }
    }
    return written;
  }
}
