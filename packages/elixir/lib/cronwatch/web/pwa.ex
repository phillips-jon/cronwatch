defmodule Cronwatch.Web.PWA do
  @moduledoc false
  # What makes the dashboard an installable web app (routes/pwa.ts): a
  # manifest, icons, a service worker, the script that registers it, and a
  # page to show offline. None of it says anything about the jobs, so it is
  # served without the token (a browser fetches the manifest and icons
  # without cookies in some flows). The files are the SDK's, byte for byte,
  # copied into assets/ (scripts/make-dashboard-icons.mjs writes the icons
  # and packages/ruby/test/web/golden.mjs the scripts and the style sheet,
  # and both fail `npm run check:conformance` when a copy here is stale),
  # read when the package compiles, so a release needs no priv lookup.

  alias Cronwatch.JS
  alias Cronwatch.JS.Object

  @assets Path.join(__DIR__, "assets")

  # The paper behind the sheet, the app window's background.
  @background_color "#f4f4f5"
  # The sheet the header sits on, light and dark.
  @theme_color "#ffffff"
  @theme_color_dark "#111113"

  @cache_year "public, max-age=31536000, immutable"
  @cache_revalidate "no-cache"

  for file <-
        ~w(style.css app.js sw.js) ++
          Enum.map(
            ~w(icon.svg maskable.svg icon-192.png icon-512.png maskable-512.png apple-touch-icon.png),
            &"icons/#{&1}"
          ) do
    @external_resource Path.join(@assets, file)
  end

  @style_css File.read!(Path.join(@assets, "style.css"))
  @app_js File.read!(Path.join(@assets, "app.js"))
  @sw_js File.read!(Path.join(@assets, "sw.js"))

  @icons %{
    "/icons/icon.svg" => {"image/svg+xml", File.read!(Path.join(@assets, "icons/icon.svg"))},
    "/icons/maskable.svg" => {"image/svg+xml", File.read!(Path.join(@assets, "icons/maskable.svg"))},
    "/icons/icon-192.png" => {"image/png", File.read!(Path.join(@assets, "icons/icon-192.png"))},
    "/icons/icon-512.png" => {"image/png", File.read!(Path.join(@assets, "icons/icon-512.png"))},
    "/icons/maskable-512.png" => {"image/png", File.read!(Path.join(@assets, "icons/maskable-512.png"))},
    "/icons/apple-touch-icon.png" => {"image/png", File.read!(Path.join(@assets, "icons/apple-touch-icon.png"))}
  }

  @doc "The pages' style sheet."
  def style_css, do: @style_css

  @doc "The header's colour, light."
  def theme_color, do: @theme_color

  @doc "The header's colour, dark."
  def theme_color_dark, do: @theme_color_dark

  @doc "The web app manifest for the dashboard mounted at `base` (`\"\"` at the root)."
  @spec manifest(String.t()) :: String.t()
  def manifest(base) do
    icon = fn name, sizes, type, purpose ->
      Object.new([
        {"src", "#{base}/icons/#{name}"},
        {"sizes", sizes},
        {"type", type},
        {"purpose", purpose}
      ])
    end

    JS.stringify(
      Object.new([
        {"id", "#{base}/"},
        {"name", "CronWatch"},
        {"short_name", "CronWatch"},
        {"description", "The scheduled jobs of this app: their health, their last day, and their runs."},
        {"start_url", "#{base}/"},
        {"scope", "#{base}/"},
        {"display", "standalone"},
        {"background_color", @background_color},
        {"theme_color", @theme_color},
        {"icons",
         [
           icon.("icon.svg", "any", "image/svg+xml", "any"),
           icon.("maskable.svg", "any", "image/svg+xml", "maskable"),
           icon.("icon-192.png", "192x192", "image/png", "any"),
           icon.("icon-512.png", "512x512", "image/png", "any"),
           icon.("maskable-512.png", "512x512", "image/png", "maskable")
         ]}
      ])
    )
  end

  @doc """
  The app shell file at `path` (the path under the base) as
  `{content_type, body, cache, worker?}`, or nil. The offline page is HTML and
  is served by the routes themselves.
  """
  @spec static_asset(String.t(), String.t()) :: {String.t(), binary(), String.t(), boolean()} | nil
  def static_asset("/manifest.webmanifest", base),
    do: {"application/manifest+json", manifest(base), @cache_revalidate, false}

  def static_asset("/app.js", _base), do: {"text/javascript; charset=utf-8", @app_js, @cache_revalidate, false}
  def static_asset("/sw.js", _base), do: {"text/javascript; charset=utf-8", @sw_js, @cache_revalidate, true}

  def static_asset(path, _base) do
    case Map.fetch(@icons, path) do
      {:ok, {type, body}} -> {type, body, @cache_year, false}
      :error -> nil
    end
  end
end
