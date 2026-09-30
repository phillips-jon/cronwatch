package dev.cronwatch.web;

import dev.cronwatch.Cronwatch;
import dev.cronwatch.Job;
import dev.cronwatch.Run;
import dev.cronwatch.RunStatus;
import dev.cronwatch.internal.core.Access;
import dev.cronwatch.internal.js.Js;
import dev.cronwatch.internal.web.Text;
import dev.cronwatch.json.JsObject;
import java.util.Objects;

/**
 * A job as an HTTP handler, the SDK's {@code job.handler()}, for a platform cron that calls a URL
 * (a Kubernetes CronJob with {@code curl}, Render, Fly.io, Cloud Run jobs behind a scheduler).
 * Framework-free like the dashboard: {@link #handle} takes a {@link Request} and answers a {@link
 * Response}, and every adapter that serves {@link Routes} serves it too. Made by {@link
 * Job#handler}. Safe to share between threads.
 *
 * <p>A request must send {@code Authorization: Bearer <secret>} (compared in constant time): the
 * options' secret, else the client's cron secret. With no secret at all it answers 503 and reports
 * it once to the error handler as {@code handler}, unless the environment is development or {@link
 * HandlerOptions.Builder#noSecret} (or the client's {@code noCronSecret()}) lets anyone in; a wrong
 * or missing bearer is 401. Each request it lets in runs the function in the request's thread as a
 * run with the trigger {@code handler}, answered with {@code {"ok","job","run","status",
 * "durationMs"}}, 200 when the run was ok and 500 when it failed, with the error's first line as
 * {@code error} for a caller who sent the secret.
 */
public final class Handler implements Endpoint {
  private final Job job;
  private final HandlerFunction fn;
  private final String secret;
  private final boolean optedOut;

  private Handler(Job job, HandlerFunction fn, HandlerOptions options) {
    this.job = Objects.requireNonNull(job, "job");
    this.fn = Objects.requireNonNull(fn, "fn");
    Cronwatch cw = job.cronwatch();
    String own = options.secret();
    if (options.secretGiven() && own == null) {
      this.secret = "";
      this.optedOut = true;
    } else if (own != null && !own.isEmpty()) {
      this.secret = own;
      this.optedOut = false;
    } else {
      this.secret = Objects.requireNonNullElse(cw.cronSecret(), "");
      this.optedOut = Access.client().secretOptOut(cw);
    }
  }

  /** The job as an HTTP handler: {@code job.handler(fn, options)}. */
  public static Handler of(Job job, HandlerFunction fn, HandlerOptions options) {
    return new Handler(job, fn, options);
  }

  /** The job this handler runs. */
  public Job job() {
    return job;
  }

  /** Names the job, never the secret. */
  @Override
  public String toString() {
    return "Handler[job=" + job.name() + "]";
  }

  /** The SDK's {@code json()}: the body, with its type and {@code no-store}. */
  private static Response json(JsObject body, int status) {
    return Response.of(status)
        .withHeader("content-type", "application/json; charset=utf-8")
        .withHeader("cache-control", "no-store")
        .withBody(Js.utf8(body.toJson()));
  }

  /**
   * Answers one request. A function that throws an {@link Error} has its run recorded, and the
   * error is thrown again.
   */
  @Override
  public Response handle(Request request) {
    Cronwatch cw = job.cronwatch();
    Access.Client access = Access.client();
    if (secret.isEmpty() && !optedOut && !access.environment(cw).equals("development")) {
      if (access.firstNoSecretRefusal(cw)) {
        cw.reportError(
            new IllegalStateException(
                "handler refused a request because no CRON_SECRET is set; pass"
                    + " HandlerOptions.noSecret() to allow unauthenticated requests"),
            "handler");
      }
      return json(
          new JsObject()
              .set("ok", false)
              .set(
                  "error",
                  "CRON_SECRET is not set, so this job will not run for an unauthenticated"
                      + " request. Set it, or pass HandlerOptions.noSecret() to handler to allow"
                      + " anyone."),
          503);
    }
    if (!secret.isEmpty()) {
      String sent = Objects.requireNonNullElse(request.header("authorization"), "");
      if (!Text.constantTimeEquals(sent, "Bearer " + secret)) {
        return json(new JsObject().set("ok", false).set("error", "Unauthorized"), 401);
      }
    }
    Access.Caught caught = access.run(job, "handler", ctx -> fn.handle(ctx, request));
    if (caught.thrown() instanceof Error e) {
      throw e;
    }
    if (caught.thrown() == null && caught.value() instanceof Response answer) {
      return answer;
    }
    Run run = caught.run();
    boolean ok = run.status().equals(RunStatus.OK);
    JsObject body =
        new JsObject()
            .set("ok", ok)
            .set("job", job.name())
            .set("run", run.id())
            .set("status", run.status().value())
            .set("durationMs", run.durationMs());
    // Error text only goes to a caller who proved they hold the secret.
    String error = run.error();
    if (!secret.isEmpty() && error != null && !error.isEmpty()) {
      int nl = error.indexOf('\n');
      body.set("error", nl < 0 ? error : error.substring(0, nl));
    }
    return json(body, ok ? 200 : 500);
  }
}
