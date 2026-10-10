// @cronwatch/sdk/webhook: the channel, and signature(), the one helper for
// a receiver, named the same in every port.
import * as internal from "../alerts/webhook.js";

export { signature, webhook } from "../alerts/webhook.js";
export type { WebhookOptions } from "../alerts/webhook.js";

/** @deprecated Renamed `signature`, the name every port uses; this name leaves the exports in 1.0. */
export const hmacSha256Hex = internal.signature;
