using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace Cronwatch.Internal;

/// <summary>One file of the app shell: its type, bytes, <c>cache-control</c>, and whether it is the service worker.</summary>
internal sealed class PwaAsset(string contentType, byte[] body, string cache, bool worker)
{
    /// <summary>Its type.</summary>
    public string ContentType { get; } = contentType;

    /// <summary>Its bytes, shared: never written to.</summary>
    public byte[] Body { get; } = body;

    /// <summary>Its <c>cache-control</c>.</summary>
    public string Cache { get; } = cache;

    /// <summary>Whether it is the service worker, which may control everything under the base.</summary>
    public bool Worker { get; } = worker;
}

/// <summary>
/// What makes the dashboard an installable web app (<c>routes/pwa.ts</c>): a manifest, icons, a
/// service worker, the script that registers it and a page to show offline. None of it says
/// anything about the jobs, so it is served without the token. The files are the SDK's, byte for
/// byte, embedded resources in the assembly: <c>scripts/make-dashboard-icons.mjs</c> writes the
/// icons and <c>packages/ruby/test/web/golden.mjs</c> the style sheet and scripts, and both fail
/// <c>npm run check:conformance</c> when a copy here is stale.
/// </summary>
internal static class Pwa
{
    /// <summary>The paper behind the sheet, the app window's background.</summary>
    public const string BackgroundColor = "#f4f4f5";

    /// <summary>The sheet the header sits on, light.</summary>
    public const string ThemeColor = "#ffffff";

    /// <summary>The sheet the header sits on, dark.</summary>
    public const string ThemeColorDark = "#111113";

    private const string CacheYear = "public, max-age=31536000, immutable";
    private const string CacheRevalidate = "no-cache";

    /// <summary>The files, read from the assembly once, when the routes are first used.</summary>
    private static class Files
    {
        public static readonly string StyleCss = Encoding.UTF8.GetString(Bytes("style.css"));
        public static readonly byte[] AppJs = Bytes("app.js");
        public static readonly byte[] SwJs = Bytes("sw.js");
        public static readonly byte[] IconSvg = Bytes("icons/icon.svg");
        public static readonly byte[] MaskableSvg = Bytes("icons/maskable.svg");
        public static readonly byte[] Icon192Png = Bytes("icons/icon-192.png");
        public static readonly byte[] Icon512Png = Bytes("icons/icon-512.png");
        public static readonly byte[] Maskable512Png = Bytes("icons/maskable-512.png");
        public static readonly byte[] AppleTouchIconPng = Bytes("icons/apple-touch-icon.png");

        private static byte[] Bytes(string name)
        {
            string resource = "Cronwatch.Web.Assets/" + name;
            using Stream stream = typeof(Pwa).Assembly.GetManifestResourceStream(resource)
                ?? throw new InvalidOperationException("the dashboard's " + resource + " is missing from the assembly");
            using var copy = new MemoryStream();
            stream.CopyTo(copy);
            return copy.ToArray();
        }
    }

    /// <summary>The pages' style sheet.</summary>
    public static string StyleCss() => Files.StyleCss;

    /// <summary>The web app manifest for the dashboard mounted at <paramref name="basePath"/> (<c>""</c> at the root).</summary>
    private static string Manifest(string basePath) => new JsObject()
        .Set("id", basePath + "/")
        .Set("name", "CronWatch")
        .Set("short_name", "CronWatch")
        .Set("description", "The scheduled jobs of this app: their health, their last day and their runs.")
        .Set("start_url", basePath + "/")
        .Set("scope", basePath + "/")
        .Set("display", "standalone")
        .Set("background_color", BackgroundColor)
        .Set("theme_color", ThemeColor)
        .Set("icons", new List<object?>
        {
            Icon(basePath, "icon.svg", "any", "image/svg+xml", "any"),
            Icon(basePath, "maskable.svg", "any", "image/svg+xml", "maskable"),
            Icon(basePath, "icon-192.png", "192x192", "image/png", "any"),
            Icon(basePath, "icon-512.png", "512x512", "image/png", "any"),
            Icon(basePath, "maskable-512.png", "512x512", "image/png", "maskable"),
        })
        .ToJson();

    private static JsObject Icon(string basePath, string name, string sizes, string type, string purpose) => new JsObject()
        .Set("src", basePath + "/icons/" + name)
        .Set("sizes", sizes)
        .Set("type", type)
        .Set("purpose", purpose);

    private static PwaAsset IconAsset(string type, byte[] body) => new(type, body, CacheYear, false);

    /// <summary>
    /// The app shell file at <paramref name="path"/> (the path under the base), or null. The
    /// offline page is HTML and is served by the routes themselves.
    /// </summary>
    public static PwaAsset? Asset(string path, string basePath) => path switch
    {
        "/manifest.webmanifest" => new PwaAsset("application/manifest+json", Js.Utf8(Manifest(basePath)), CacheRevalidate, false),
        "/app.js" => new PwaAsset("text/javascript; charset=utf-8", Files.AppJs, CacheRevalidate, false),
        "/sw.js" => new PwaAsset("text/javascript; charset=utf-8", Files.SwJs, CacheRevalidate, true),
        "/icons/icon.svg" => IconAsset("image/svg+xml", Files.IconSvg),
        "/icons/maskable.svg" => IconAsset("image/svg+xml", Files.MaskableSvg),
        "/icons/icon-192.png" => IconAsset("image/png", Files.Icon192Png),
        "/icons/icon-512.png" => IconAsset("image/png", Files.Icon512Png),
        "/icons/maskable-512.png" => IconAsset("image/png", Files.Maskable512Png),
        "/icons/apple-touch-icon.png" => IconAsset("image/png", Files.AppleTouchIconPng),
        _ => null,
    };
}
