package dev.cronwatch.alerts;

import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicBoolean;
import org.jspecify.annotations.Nullable;

/**
 * An answer to a {@link Transport}'s request: its status, and its body as it arrives. Closing it
 * lets go of what is left of the body (the JDK transport cancels its subscription, which closes the
 * connection).
 */
public final class Response implements AutoCloseable {
  /** An answer's body, read a chunk at a time. */
  @FunctionalInterface
  public interface Body {
    /**
     * The next chunk, or null at the end. It may block until the chunk arrives, and must give up
     * when its thread is interrupted.
     *
     * @throws Exception when the body could not be read
     */
    byte @Nullable [] next() throws Exception;

    /**
     * Lets go of what is left of the body. Nothing by default.
     *
     * @throws Exception when that failed, which is ignored
     */
    default void close() throws Exception {}
  }

  private final int status;
  private final Body body;

  /** An answer of this status whose body arrives through {@code body}. */
  public Response(int status, Body body) {
    this.status = status;
    this.body = body;
  }

  /** An answer whose whole body is at hand. */
  public static Response of(int status, byte[] body) {
    byte[] copy = body.clone();
    AtomicBoolean read = new AtomicBoolean();
    return new Response(status, () -> read.getAndSet(true) ? null : copy.clone());
  }

  /** An answer whose whole body is this text, as UTF-8. */
  public static Response of(int status, String body) {
    return of(status, body.getBytes(StandardCharsets.UTF_8));
  }

  /** The status. */
  public int status() {
    return status;
  }

  /** The body, to read a chunk at a time. */
  public Body body() {
    return body;
  }

  /** Lets go of what is left of the body; a failure doing so is ignored. */
  @Override
  public void close() {
    try {
      body.close();
    } catch (Exception e) {
      // Nothing is left to read either way.
    }
  }

  @Override
  public String toString() {
    return "Response[" + status + "]";
  }
}
