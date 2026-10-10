/** This release of @cronwatch/sdk. scripts/release.mjs keeps it in step with package.json. */
export const VERSION = "0.12.5";

/**
 * The dashboard JSON API's version, which GET <base>/api answers. It goes up
 * only for a change that is not additive (a field removed or retyped, a path
 * moved), and such a change waits for a major release.
 */
export const API_VERSION = 1;
