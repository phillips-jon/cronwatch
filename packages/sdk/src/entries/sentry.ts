// @cronwatch/sdk/sentry: what the entry point exports. parseDsn is internal
// to the channel; it is kept, deprecated, and leaves the exports in 1.0.
import * as internal from "../alerts/sentry.js";

export { sentry } from "../alerts/sentry.js";
export type { SentryOptions } from "../alerts/sentry.js";

/** @deprecated Internal to the Sentry channel; leaves the exports in 1.0. */
export const parseDsn = internal.parseDsn;
