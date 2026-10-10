// @cronwatch/sdk/discord: what the entry point exports. The helpers the
// channel is built from are internal; the names below are kept, deprecated,
// for anyone who imported them, and leave the exports in 1.0.
import * as internal from "../alerts/discord.js";

export { discord } from "../alerts/discord.js";
export type { DiscordOptions } from "../alerts/discord.js";

/** @deprecated Internal to the Discord channel; leaves the exports in 1.0. */
export const DESCRIPTION_MAX = internal.DESCRIPTION_MAX;
/** @deprecated Internal to the Discord channel; leaves the exports in 1.0. */
export const embedDescription = internal.embedDescription;
/** @deprecated Internal to the Discord channel; leaves the exports in 1.0. */
export const codeBlockSafe = internal.codeBlockSafe;
/** @deprecated Internal to the Discord channel; leaves the exports in 1.0. */
export const escapeMarkdown = internal.escapeMarkdown;
