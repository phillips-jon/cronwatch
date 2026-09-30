package dev.cronwatch;

import dev.cronwatch.alerts.JdkTransport;
import dev.cronwatch.alerts.Transport;
import dev.cronwatch.alerts.Transport.Request;
import dev.cronwatch.alerts.Transport.Response;
import java.util.concurrent.locks.ReentrantLock;
import org.jspecify.annotations.Nullable;

/**
 * The client's default transport: a {@link JdkTransport} made on the first send, so a client that
 * never alerts over HTTP never starts an {@code HttpClient}, and closed with the client, so no
 * thread of it outlives an app that is undeployed.
 */
final class LazyTransport implements Transport, AutoCloseable {
  private final ReentrantLock lock = new ReentrantLock();
  private @Nullable JdkTransport made;
  private boolean closed;

  @Override
  public Response post(Request request) throws Exception {
    return transport().post(request);
  }

  private JdkTransport transport() {
    lock.lock();
    try {
      if (closed) {
        throw new IllegalStateException("the client is closed");
      }
      JdkTransport t = made;
      if (t == null) {
        t = new JdkTransport();
        made = t;
      }
      return t;
    } finally {
      lock.unlock();
    }
  }

  /** Closes the transport, if one was made; sends after this fail. */
  @Override
  public void close() {
    lock.lock();
    try {
      closed = true;
      if (made != null) {
        made.close();
      }
    } finally {
      lock.unlock();
    }
  }

  @Override
  public String toString() {
    return "JdkTransport";
  }
}
