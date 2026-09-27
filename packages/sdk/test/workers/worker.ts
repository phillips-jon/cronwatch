/**
 * A sample Worker, bundled by workers.test.ts for workerd and run in
 * Miniflare without nodejs_compat. It is the pattern the Cloudflare docs
 * page shows: the client is made per invocation from env, jobs run from a
 * Cron Trigger, the check runs from another, and fetch serves the dashboard.
 */
import { cronwatch, custom } from "../../src/index.js";
import { d1, type D1DatabaseLike } from "../../src/stores/d1.js";

interface Env {
  DB: D1DatabaseLike;
  CRONWATCH_TOKEN?: string;
  CRON_SECRET?: string;
}
interface ScheduledController { cron: string; scheduledTime: number }
interface ExecutionContext { waitUntil(promise: Promise<unknown>): void }

function monitor(env: Env) {
  const cw = cronwatch({
    store: d1(env.DB),
    cronSecret: env.CRON_SECRET,
    // Alerts land in a table the test reads, so delivery inside waitUntil is checked too.
    alerts: [custom("table", async (alert) => {
      await env.DB.prepare("INSERT INTO test_alerts (job, type, title) VALUES (?, ?, ?)").bind(alert.job, alert.type, alert.title).run();
    })],
  });
  return {
    cw,
    nightly: cw.job("nightly", { schedule: "0 2 * * *", grace: "15m" }),
    hourly: cw.job("hourly", { schedule: "0 * * * *", grace: "5m" }),
  };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/cronwatch" || url.pathname.startsWith("/cronwatch/")) {
      return monitor(env).cw.routes({ token: env.CRONWATCH_TOKEN }).handler(request);
    }
    if (url.pathname === "/fail") {
      // A job that throws, run from fetch: the run is recorded and the error rethrown.
      const { nightly } = monitor(env);
      try {
        await nightly.run(() => { throw new Error("upstream was down"); }, { trigger: "fetch" });
      } catch (e) {
        return new Response((e as Error).message, { status: 500 });
      }
    }
    return new Response("Not found", { status: 404 });
  },

  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    const { cw, nightly } = monitor(env);
    if (controller.cron === "*/5 * * * *") {
      ctx.waitUntil(cw.check());
    } else if (controller.cron === "0 2 * * *") {
      ctx.waitUntil(nightly.run(async (job) => {
        job.log("rows: 3");
        job.metric("rows", 3);
      }, { trigger: "cron" }));
    }
  },
};
