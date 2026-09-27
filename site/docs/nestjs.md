---
title: NestJS
description: A module that provides the client, @Cron methods wrapped with job.run(), and the dashboard through a controller.
order: 3.33
group: More platforms
---

# NestJS

`@nestjs/schedule` runs `@Cron` methods inside the application process, so a Nest app has everything in one place: the jobs, the check, and the dashboard. This page assumes the default Express platform.

## A module for the client

The SDK's `CronWatch` class works as the injection token, so services ask for it by type. The module starts the check once the application has booted and closes the client on shutdown.

```ts
// src/cronwatch/cronwatch.module.ts
import { Global, Module, type OnApplicationBootstrap, type OnApplicationShutdown } from "@nestjs/common";
import { CronWatch, cronwatch } from "@cronwatch/sdk";
import { postgres } from "@cronwatch/sdk/postgres";
import { slack } from "@cronwatch/sdk/slack";
import { CronwatchController } from "./cronwatch.controller";

@Global()
@Module({
  providers: [
    {
      provide: CronWatch,
      useFactory: () =>
        cronwatch({
          store: postgres({ connectionString: process.env.DATABASE_URL }),
          alerts: [slack({ webhookUrl: process.env.SLACK_WEBHOOK_URL! })],
        }),
    },
  ],
  controllers: [CronwatchController],
  exports: [CronWatch],
})
export class CronwatchModule implements OnApplicationBootstrap, OnApplicationShutdown {
  constructor(private readonly cw: CronWatch) {}

  onApplicationBootstrap() {
    this.cw.start("1m");
  }

  async onApplicationShutdown() {
    await this.cw.close();
  }
}
```

Import it in the root module next to `ScheduleModule.forRoot()`. `onApplicationShutdown` only runs after `app.enableShutdownHooks()`.

```ts
// src/main.ts
const app = await NestFactory.create(AppModule, { rawBody: true });
app.enableShutdownHooks();
await app.listen(3000);
```

`rawBody: true` is for the dashboard below. SQLite (`@cronwatch/sdk/sqlite`) works as well when the app runs on one server with a persistent disk.

## Wrapping a @Cron method

Declare the job in the constructor and wrap the method body in `run()`. Give the declaration the same expression and zone as the decorator. `@nestjs/schedule` takes a six-field expression with seconds first, which CronWatch reads the same way.

```ts
// src/reports/reports.service.ts
import { Injectable } from "@nestjs/common";
import { Cron } from "@nestjs/schedule";
import { CronWatch, type JobHandle } from "@cronwatch/sdk";

@Injectable()
export class ReportsService {
  private readonly nightly: JobHandle;

  constructor(cw: CronWatch) {
    this.nightly = cw.job("nightly-report", {
      schedule: "0 0 2 * * *",
      timezone: "Europe/London",
      timeout: "30m",
    });
  }

  @Cron("0 0 2 * * *", { name: "nightly-report", timeZone: "Europe/London", waitForCompletion: true })
  async nightlyReport() {
    await this.nightly.run(async (job) => {
      const report = await buildReport();
      job.log("Report written:", report.path);
      job.metric("cost", report.usdCost);
    });
  }
}
```

`run()` rethrows, and `@nestjs/schedule` catches and logs what a `@Cron` method throws, so a failure is recorded, alerted and logged, and the scheduler carries on.

Without a `timeZone` the decorator uses the server's zone, and so does a job without `timezone`; set both or neither. `waitForCompletion: true` skips a tick that arrives while the previous run is still going. CronWatch then reports the skipped slot as missed once the grace passes, since nothing started. `@Interval(ms)` methods can be wrapped the same way, declared with `schedule: "every 15m"`.

## Several instances

Every instance of the app runs every `@Cron` method. All of their runs are recorded in a shared store, but if the work must happen once, guard it (a lock in the database, or a single worker instance) and run the check on that instance only; see [several instances](/docs/limits/#several-instances).

## The dashboard

`routes()` is fetch-style, and Express hands a controller Node's request and response, so a small adapter converts between the two. It is framework-free and works anywhere you have Node's `IncomingMessage` and `ServerResponse`.

```ts
// src/cronwatch/node-fetch.ts
import type { IncomingMessage, ServerResponse } from "node:http";

const first = (value: string | string[] | undefined) => (Array.isArray(value) ? value[0] : value)?.split(",")[0]?.trim();

/** A fetch Request for a Node request. Pass rawBody when a body parser has already read the stream. */
export async function toRequest(req: IncomingMessage, rawBody?: Buffer): Promise<Request> {
  const proto = first(req.headers["x-forwarded-proto"]) ?? ("encrypted" in req.socket && req.socket.encrypted ? "https" : "http");
  const host = first(req.headers["x-forwarded-host"]) ?? req.headers.host ?? "localhost";
  const headers = new Headers();
  for (const [name, value] of Object.entries(req.headers)) {
    for (const v of Array.isArray(value) ? value : value === undefined ? [] : [value]) headers.append(name, v);
  }
  const method = req.method ?? "GET";
  let body: BodyInit | undefined;
  if (method !== "GET" && method !== "HEAD") {
    if (rawBody) body = new Uint8Array(rawBody);
    else if (!req.readableEnded) body = new Uint8Array(Buffer.concat(await req.toArray()));
  }
  return new Request(`${proto}://${host}${req.url ?? "/"}`, { method, headers, body });
}

/** Writes a fetch Response to a Node response. */
export async function send(res: ServerResponse, response: Response): Promise<void> {
  const headers: Record<string, string | string[]> = {};
  response.headers.forEach((value, name) => {
    if (name !== "set-cookie") headers[name] = value;
  });
  const cookies = response.headers.getSetCookie();
  if (cookies.length) headers["set-cookie"] = cookies;
  res.writeHead(response.status, headers);
  res.end(Buffer.from(await response.arrayBuffer()));
}
```

The URL is rebuilt from `X-Forwarded-Proto` and `X-Forwarded-Host` when a proxy sets them, because the routes compare a form post's `Origin` with the request's own origin and refuse a mismatch as cross-site. Behind a TLS-terminating proxy that does not set them, dashboard forms would be refused.

The controller hands every method and every path under `/cronwatch` to the routes:

```ts
// src/cronwatch/cronwatch.controller.ts
import { All, Controller, Req, Res, type RawBodyRequest } from "@nestjs/common";
import { CronWatch, type Routes } from "@cronwatch/sdk";
import type { Request, Response } from "express";
import { send, toRequest } from "./node-fetch";

@Controller("cronwatch")
export class CronwatchController {
  private readonly routes: Routes;

  constructor(cw: CronWatch) {
    this.routes = cw.routes({ basePath: "/cronwatch" });
  }

  @All(["", "*path"])
  async serve(@Req() req: RawBodyRequest<Request>, @Res() res: Response) {
    await send(res, await this.routes.handler(await toRequest(req, req.rawBody)));
  }
}
```

Nest's body parser has read the request stream before the controller runs, which is why the app is created with `rawBody: true`: the silence form's body is passed on from `req.rawBody`. If the app sets a global prefix, include it in `basePath` (`/api/cronwatch` for `setGlobalPrefix("api")`). Set `CRONWATCH_TOKEN` and open `/cronwatch?token=<it>` once.
