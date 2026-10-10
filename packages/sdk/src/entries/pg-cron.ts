// @cronwatch/sdk/pg-cron: what the entry point exports. The helpers the
// source is built from are internal; the names below are kept, deprecated,
// for anyone who imported them, and leave the exports in 1.0.
import * as internal from "../sources/pgcron.js";

export { pgCron } from "../sources/pgcron.js";
export type { PgCronJob, PgCronOptions, Queryable } from "../sources/pgcron.js";

/** @deprecated Internal to the pg_cron source; leaves the exports in 1.0. */
export const PG_CRON_HOLD_MS = internal.PG_CRON_HOLD_MS;
/** @deprecated Internal to the pg_cron source; leaves the exports in 1.0. */
export const pgCronSchedule = internal.pgCronSchedule;
/** @deprecated Internal to the pg_cron source; leaves the exports in 1.0. */
export const pgCronJobName = internal.pgCronJobName;
/** @deprecated Internal to the pg_cron source; leaves the exports in 1.0. */
export const pgCronRun = internal.pgCronRun;
