//! What makes the dashboard an installable web app (routes/pwa.ts): a
//! manifest, icons, a service worker, the script that registers it and a
//! page to show offline. None of it says anything about the jobs, so it is
//! served without the token (a browser fetches the manifest and icons
//! without cookies in some flows). The files are the SDK's, byte for byte:
//! `scripts/make-dashboard-icons.mjs` writes the icons and
//! `packages/ruby/test/web/golden.mjs` the scripts, and both fail
//! `npm run check:conformance` when a copy here is stale.

use std::borrow::Cow;

use crate::js::{Object, Value};

/// The paper behind the sheet, the app window's background.
pub(crate) const BACKGROUND_COLOR: &str = "#f4f4f5";
/// The sheet the header sits on, light and dark.
pub(crate) const THEME_COLOR: &str = "#ffffff";
pub(crate) const THEME_COLOR_DARK: &str = "#111113";

/// The pages' style sheet.
pub(crate) const STYLE_CSS: &str = include_str!("assets/style.css");
/// The script every page loads: it registers the service worker, nothing else.
pub(crate) const APP_JS: &str = include_str!("assets/app.js");
/// The service worker, which caches the app shell and the offline page only.
pub(crate) const SW_JS: &str = include_str!("assets/sw.js");

const CACHE_YEAR: &str = "public, max-age=31536000, immutable";
const CACHE_REVALIDATE: &str = "no-cache";

/// One file of the app shell.
pub(crate) struct ShellAsset {
    pub content_type: &'static str,
    pub body: Cow<'static, [u8]>,
    pub cache: &'static str,
    /// The service worker, which may control everything under the base.
    pub worker: bool,
}

/// The web app manifest for the dashboard mounted at `base` (`""` at the
/// root).
pub(crate) fn manifest(base: &str) -> String {
    let icon = |name: &str, sizes: &str, kind: &str, purpose: &str| -> Value {
        Value::Object(
            Object::new()
                .with("src", format!("{base}/icons/{name}"))
                .with("sizes", sizes)
                .with("type", kind)
                .with("purpose", purpose),
        )
    };
    Object::new()
        .with("id", format!("{base}/"))
        .with("name", "CronWatch")
        .with("short_name", "CronWatch")
        .with("description", "The scheduled jobs of this app: their health, their last day and their runs.")
        .with("start_url", format!("{base}/"))
        .with("scope", format!("{base}/"))
        .with("display", "standalone")
        .with("background_color", BACKGROUND_COLOR)
        .with("theme_color", THEME_COLOR)
        .with(
            "icons",
            vec![
                icon("icon.svg", "any", "image/svg+xml", "any"),
                icon("maskable.svg", "any", "image/svg+xml", "maskable"),
                icon("icon-192.png", "192x192", "image/png", "any"),
                icon("icon-512.png", "512x512", "image/png", "any"),
                icon("maskable-512.png", "512x512", "image/png", "maskable"),
            ],
        )
        .to_json()
}

fn icon(content_type: &'static str, body: &'static [u8]) -> ShellAsset {
    ShellAsset { content_type, body: Cow::Borrowed(body), cache: CACHE_YEAR, worker: false }
}

/// The app shell file at `path` (the path under the base), or `None`. The
/// offline page is HTML and is served by the routes themselves.
pub(crate) fn static_asset(path: &str, base: &str) -> Option<ShellAsset> {
    let text = |content_type, body: &'static str, worker| ShellAsset {
        content_type,
        body: Cow::Borrowed(body.as_bytes()),
        cache: CACHE_REVALIDATE,
        worker,
    };
    Some(match path {
        "/manifest.webmanifest" => ShellAsset {
            content_type: "application/manifest+json",
            body: Cow::Owned(manifest(base).into_bytes()),
            cache: CACHE_REVALIDATE,
            worker: false,
        },
        "/app.js" => text("text/javascript; charset=utf-8", APP_JS, false),
        "/sw.js" => text("text/javascript; charset=utf-8", SW_JS, true),
        "/icons/icon.svg" => icon("image/svg+xml", include_bytes!("assets/icons/icon.svg")),
        "/icons/maskable.svg" => icon("image/svg+xml", include_bytes!("assets/icons/maskable.svg")),
        "/icons/icon-192.png" => icon("image/png", include_bytes!("assets/icons/icon-192.png")),
        "/icons/icon-512.png" => icon("image/png", include_bytes!("assets/icons/icon-512.png")),
        "/icons/maskable-512.png" => icon("image/png", include_bytes!("assets/icons/maskable-512.png")),
        "/icons/apple-touch-icon.png" => icon("image/png", include_bytes!("assets/icons/apple-touch-icon.png")),
        _ => return None,
    })
}
