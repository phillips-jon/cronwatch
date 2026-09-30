package dev.cronwatch.alerts;

/**
 * Sends one POST and answers its status and body, whatever the status: the one request every
 * channel and Claude triage make. {@link JdkTransport} over the JDK's {@code HttpClient} is the
 * default; an app that wants OkHttp, Apache HttpClient, a proxy or its own trust store writes one,
 * and gives it to the client ({@code Cronwatch.builder().transport(...)}) or to a channel's
 * options.
 *
 * <p>A transport must not follow redirects: a 3xx is an answer like any other, and the channel
 * fails on it, so credential headers never go where it points. The deadline (ten seconds for the
 * whole request) and the answer's cap (1 MiB) are held around the transport whatever it does: it is
 * called on a virtual thread of its own, interrupted past the deadline, and its body is read a
 * chunk at a time and closed at the cap. Its exceptions are rewritten so they name only the URL's
 * origin, since a webhook URL's path or query is often its credential.
 */
@FunctionalInterface
public interface Transport {
  /**
   * Sends the request and answers once the answer's head has arrived; the body is read from the
   * response afterwards, a chunk at a time.
   *
   * @throws Exception when no answer came
   */
  Response post(Request request) throws Exception;
}
