<?php

declare(strict_types=1);

namespace Cronwatch\Bridge;

use Cronwatch\Web\Request;
use Cronwatch\Web\Response;

/**
 * The dashboard served inside a CMS's admin (Drupal's, Craft's control
 * panel), where every page is one route of the host's and the dashboard's
 * path rides in a query parameter: `.../cronwatch/view?cw=/jobs/nightly`.
 * The host's router, its sign-in and its permissions stand in front of it.
 *
 * The dashboard is given a marker as its base path, so every link, form
 * action and redirect it makes starts with the marker; rewrite() turns each
 * into the host's URL for that path (the host adds its CSRF token to a
 * form's action, or a hidden field to the form), leaves out the app shell
 * (the manifest and app.js, which registers a service worker: the admin is
 * not where the dashboard is installed as an app), and lets the host's own
 * pages frame it. Nothing a page shows can end an attribute value with the
 * marker, since text is escaped. The WordPress plugin does the same with
 * WordPress's functions (wordpress/includes/AdminDashboard.php).
 *
 * @internal For the framework integrations.
 */
final class EmbeddedDashboard
{
    /** The base path the dashboard is given, rewritten in every link. */
    public const MARKER = '/__cronwatch_embedded__';

    /**
     * The dashboard's request for the page at `path` (the host's `cw`
     * parameter), from the request the host is answering: its method,
     * headers, body and origin, and its query without the host's own keys.
     * The Authorization header is left out: the host's sign-in and
     * permissions stand in front of the dashboard, which is open, so a
     * bearer the caller sends is not the dashboard's, and must not let a GET
     * run the check (a GET of /api/check runs it only with a bearer).
     *
     * @param list<string> $reserved the query keys the host uses (the path's, a CSRF token's)
     */
    public static function request(Request $request, string $path, array $reserved): Request
    {
        $headers = $request->headers;
        unset($headers['authorization']);
        if (!str_starts_with($path, '/')) {
            $path = '/' . $path;
        }
        $query = [];
        foreach (explode('&', $request->query) as $pair) {
            $name = urldecode(explode('=', $pair, 2)[0]);
            if ($pair !== '' && !in_array($name, $reserved, true)) {
                $query[] = $pair;
            }
        }
        return new Request(
            $request->method,
            Request::normalizePath(self::MARKER . explode('?', $path, 2)[0]),
            implode('&', $query),
            $headers,
            static fn (): string => $request->body(),
            $request->origin,
            null,
            $request->form,
        );
    }

    /**
     * The dashboard's answer made to live in the host: links, forms and
     * redirects under the marker point where `url` says, forms carry what
     * `action` adds to their URL and the `fields` given (hidden inputs,
     * already HTML), the app shell is left out, and the host may frame it.
     *
     * @param \Closure(string $path, array<string, string> $query): string $url the host's URL for the dashboard's page at a path
     * @param (\Closure(string $url): string)|null $action a form's action from its URL (a CSRF token added), default the URL
     * @param string $fields HTML put at the start of every form (a hidden CSRF field)
     */
    public static function rewrite(Response $response, \Closure $url, ?\Closure $action = null, string $fields = ''): Response
    {
        $headers = $response->headers;
        if (isset($headers['location']) && str_starts_with($headers['location'], self::MARKER)) {
            $headers['location'] = self::target(substr($headers['location'], strlen(self::MARKER)), $url);
        }
        if (isset($headers['x-frame-options'])) {
            $headers['x-frame-options'] = 'SAMEORIGIN';
        }
        if (isset($headers['content-security-policy'])) {
            $headers['content-security-policy'] = str_replace("frame-ancestors 'none'", "frame-ancestors 'self'", $headers['content-security-policy']);
        }
        $body = $response->body;
        if (str_starts_with((string) ($headers['content-type'] ?? ''), 'text/html')) {
            $marker = preg_quote(self::MARKER, '#');
            $body = (string) preg_replace("#\n<link rel=\"manifest\" href=\"{$marker}/manifest\\.webmanifest\">|\n<script src=\"{$marker}/app\\.js\" defer></script>#", '', $body);
            $body = (string) preg_replace_callback("#(\\s(?:href|action|src)=)\"{$marker}(/[^\"]*)\"#", function (array $m) use ($url, $action): string {
                $target = self::target(html_entity_decode($m[2], ENT_QUOTES | ENT_HTML5, 'UTF-8'), $url);
                if ($action !== null && str_starts_with($m[1], ' action')) {
                    $target = $action($target);
                }
                return $m[1] . '"' . htmlspecialchars($target, ENT_QUOTES | ENT_HTML5, 'UTF-8') . '"';
            }, $body);
            if ($fields !== '') {
                $body = (string) preg_replace('#(<form\b[^>]*\bmethod="post"[^>]*>)#', '$1' . str_replace(['\\', '$'], ['\\\\', '\\$'], $fields), $body);
            }
        }
        return new Response($response->status, $headers, $body);
    }

    /** The host's URL for a dashboard path that may carry a query (`/jobs/x?runs=100`). */
    private static function target(string $path, \Closure $url): string
    {
        [$path, $query] = array_pad(explode('?', $path === '' ? '/' : $path, 2), 2, '');
        $params = [];
        foreach (Request::parseQuery($query) as [$name, $value]) {
            $params[$name] ??= $value;
        }
        return $url($path === '' ? '/' : $path, $params);
    }
}
