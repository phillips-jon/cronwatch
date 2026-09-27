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
const app = await NestFactory.create(AppModule);
app.enableShutdownHooks();
await app.listen(3000);
```

SQLite (`@cronwatch/sdk/sqlite`) works as well when the app runs on one server with a persistent disk.

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

`routes()` is fetch-style, and Express hands a controller Node's request and response. `toNodeHandler` from `@cronwatch/sdk/node` converts between the two (see [Express and other Node servers](/docs/node/#express-koa-and-plain-node-servers)). The controller hands every method and every path under `/cronwatch` to it:

```ts
// src/cronwatch/cronwatch.controller.ts
import { All, Controller, Req, Res } from "@nestjs/common";
import { CronWatch } from "@cronwatch/sdk";
import { toNodeHandler, type NodeHandler } from "@cronwatch/sdk/node";
import type { Request, Response } from "express";

@Controller("cronwatch")
export class CronwatchController {
  private readonly serveRoutes: NodeHandler;

  constructor(cw: CronWatch) {
    this.serveRoutes = toNodeHandler(cw.routes({ basePath: "/cronwatch" }).handler);
  }

  @All(["", "*path"])
  serve(@Req() req: Request, @Res() res: Response) {
    return this.serveRoutes(req, res);
  }
}
```

Nest's body parser reads the request before the controller runs. The adapter uses `req.rawBody` when the app is created with `rawBody: true`, and otherwise encodes the parsed `req.body` again as the form or JSON it came as, so the silence form works either way. If the app sets a global prefix, include it in `basePath` (`/api/cronwatch` for `setGlobalPrefix("api")`). Set `CRONWATCH_TOKEN` and open `/cronwatch?token=<it>` once.

Behind a proxy that terminates TLS, the dashboard's forms are refused as cross-site unless the routes know the public origin: pass `origin: "https://app.example.com"` to `cw.routes()`, or `trustProxy: true` to `toNodeHandler` when the proxy sets `X-Forwarded-Proto` and `X-Forwarded-Host`. See [behind a proxy](/docs/dashboard/#behind-a-proxy).

