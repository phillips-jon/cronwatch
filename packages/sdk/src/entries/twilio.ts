// @cronwatch/sdk/twilio: what the entry point exports. The helpers the
// channel is built from are internal; the names below are kept, deprecated,
// for anyone who imported them, and leave the exports in 1.0.
import * as internal from "../alerts/twilio.js";

export { twilio } from "../alerts/twilio.js";
export type { TwilioOptions } from "../alerts/twilio.js";

/** @deprecated Internal to the Twilio channel; leaves the exports in 1.0. */
export const MAX_SEGMENTS = internal.MAX_SEGMENTS;
/** @deprecated Internal to the Twilio channel; leaves the exports in 1.0. */
export const MAX_BODY = internal.MAX_BODY;
/** @deprecated Internal to the Twilio channel; leaves the exports in 1.0. */
export const smsSegments = internal.smsSegments;
/** @deprecated Internal to the Twilio channel; leaves the exports in 1.0. */
export const smsBody = internal.smsBody;
