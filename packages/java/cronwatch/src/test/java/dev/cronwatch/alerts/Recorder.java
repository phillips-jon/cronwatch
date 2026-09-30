package dev.cronwatch.alerts;

import dev.cronwatch.alerts.Transport.Request;
import dev.cronwatch.alerts.Transport.Response;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Function;

/**
 * A transport that keeps each request and answers each with the status and body {@code answer}
 * gives for its body, as the SDK's tests stub fetch.
 */
final class Recorder implements Transport {
  /** A status and a body. */
  record Reply(int status, String body) {}

  private final List<Request> taken = new ArrayList<>();
  private Function<String, Reply> answer;

  Recorder(int status, String body) {
    this.answer = b -> new Reply(status, body);
  }

  synchronized void answer(Function<String, Reply> answer) {
    this.answer = answer;
    taken.clear();
  }

  synchronized void answerWith(int status, String body) {
    answer(b -> new Reply(status, body));
  }

  synchronized List<Request> taken() {
    return new ArrayList<>(taken);
  }

  /** The value of a header of the {@code i}th request, or {@code ""}. */
  synchronized String header(int i, String name) {
    String v = taken.get(i).header(name);
    return v == null ? "" : v;
  }

  static String body(Request r) {
    return new String(r.body(), StandardCharsets.UTF_8);
  }

  @Override
  public Response post(Request request) {
    Reply reply;
    synchronized (this) {
      reply = answer.apply(body(request));
      taken.add(request);
    }
    return Response.of(reply.status(), reply.body());
  }
}
