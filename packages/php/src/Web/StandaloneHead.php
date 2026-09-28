<?php

declare(strict_types=1);

namespace Cronwatch\Web;

/**
 * The head of a dashboard page served as a site of its own, as the SDK's
 * routes serve it: the web app manifest, the icons, app.js (the one script,
 * which only registers the service worker, Pwa) and the stylesheet inline.
 * A host that shows the dashboard inside its own pages and loads a page's
 * assets its own way gives Dashboard a `head` instead, and this is not used.
 *
 * @internal
 */
final class StandaloneHead
{
    /** The lines for the dashboard mounted at a base ("" at the root), given already escaped. */
    public static function html(string $b): string
    {
        return "<link rel=\"manifest\" href=\"{$b}/manifest.webmanifest\">\n"
            . "<link rel=\"icon\" href=\"{$b}/icons/icon.svg\" type=\"image/svg+xml\">\n"
            . "<link rel=\"apple-touch-icon\" href=\"{$b}/icons/apple-touch-icon.png\">\n"
            . "<script src=\"{$b}/app.js\" defer></script>\n"
            . '<style>' . Html::CSS . "</style>\n";
    }
}
