package cronwatch

// What makes the dashboard an installable web app (routes/pwa.ts): a
// manifest, icons, a service worker, the script that registers it, and a
// page to show offline. None of it says anything about the jobs, so it is
// served without the token (a browser fetches the manifest and icons
// without cookies in some flows).

import (
	"encoding/base64"
	"sync"

	"cronwatch.dev/go/internal/js"
)

// The page colours the app's window takes: the paper behind the sheet, and
// the sheet the header sits on.
const (
	pwaBackgroundColor = "#f4f4f5"
	pwaThemeColor      = "#ffffff"
	pwaThemeColorDark  = "#111113"
)

// manifest is the web app manifest for the dashboard mounted at base (""
// at the root).
func manifest(base string) string {
	icon := func(name, sizes, typ, purpose string) any {
		return js.NewObject("src", base+"/icons/"+name, "sizes", sizes, "type", typ, "purpose", purpose)
	}
	return js.Stringify(js.NewObject(
		"id", base+"/",
		"name", "CronWatch",
		"short_name", "CronWatch",
		"description", "The scheduled jobs of this app: their health, their last day, and their runs.",
		"start_url", base+"/",
		"scope", base+"/",
		"display", "standalone",
		"background_color", pwaBackgroundColor,
		"theme_color", pwaThemeColor,
		"icons", []any{
			icon("icon.svg", "any", "image/svg+xml", "any"),
			icon("maskable.svg", "any", "image/svg+xml", "maskable"),
			icon("icon-192.png", "192x192", "image/png", "any"),
			icon("icon-512.png", "512x512", "image/png", "any"),
			icon("maskable-512.png", "512x512", "image/png", "maskable"),
		},
	))
}

// shellAsset is one file of the app shell.
type shellAsset struct {
	typ   string
	body  []byte
	cache string
	// The service worker, which may control everything under the base.
	worker bool
}

const (
	cacheYear       = "public, max-age=31536000, immutable"
	cacheRevalidate = "no-cache"
)

// iconFiles are the icons by their path under the base, decoded once.
var iconFiles = sync.OnceValue(func() map[string]shellAsset {
	png := func(b64 string) shellAsset {
		data, err := base64.StdEncoding.DecodeString(b64)
		if err != nil {
			panic("cronwatch: a dashboard icon is not base64: " + err.Error())
		}
		return shellAsset{typ: "image/png", body: data, cache: cacheYear}
	}
	return map[string]shellAsset{
		"/icons/icon.svg":             {typ: "image/svg+xml", body: []byte(iconSVG), cache: cacheYear},
		"/icons/maskable.svg":         {typ: "image/svg+xml", body: []byte(maskableSVG), cache: cacheYear},
		"/icons/icon-192.png":         png(icon192PNG),
		"/icons/icon-512.png":         png(icon512PNG),
		"/icons/maskable-512.png":     png(maskable512PNG),
		"/icons/apple-touch-icon.png": png(appleTouchIconPNG),
	}
})

// staticAsset is the app shell file at path (the path under the base), or
// false. The offline page is HTML and is served by the routes themselves.
func staticAsset(path, base string) (shellAsset, bool) {
	switch path {
	case "/manifest.webmanifest":
		return shellAsset{typ: "application/manifest+json", body: []byte(manifest(base)), cache: cacheRevalidate}, true
	case "/app.js":
		return shellAsset{typ: "text/javascript; charset=utf-8", body: []byte(appJS), cache: cacheRevalidate}, true
	case "/sw.js":
		return shellAsset{typ: "text/javascript; charset=utf-8", body: []byte(swJS), cache: cacheRevalidate, worker: true}, true
	}
	asset, ok := iconFiles()[path]
	return asset, ok
}
