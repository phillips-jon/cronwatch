<?php

declare(strict_types=1);

namespace Cronwatch\WordPress;

\defined('ABSPATH') || exit;

use Cronwatch\Web\Dashboard;
use Cronwatch\Web\Request;
use Cronwatch\Web\Response;

/**
 * The library's dashboard in wp-admin, under its own CronWatch menu, for
 * users who may manage options.
 *
 * The dashboard is a page of its own (its own stylesheet, with a strict
 * CSP), so the wp-admin page shows it in a frame: admin.php?page=cronwatch is
 * the admin screen with the frame in it, and admin.php?page=cronwatch&cw=<path>
 * is the dashboard's page at <path>, answered from the load-<hook> action,
 * before wp-admin writes anything. WordPress has already checked the login
 * and the manage_options capability by then (the menu page asks for it),
 * and the handler checks it again; it is never a public URL. The dashboard
 * runs open (token false), since WordPress is its sign-in, and every change
 * (a POST from its forms) must carry a WordPress nonce as well as pass the
 * dashboard's own same-origin check.
 *
 * The dashboard's links are paths under its base path, so it is given a
 * marker as its base and every link, form and redirect under the marker is
 * rewritten to admin.php?page=cronwatch&cw=<path> (with the nonce on each
 * form's action). Its pages' head is the plugin's (head()): the dashboard's
 * stylesheet, css/dashboard.css (the library's Html::CSS, which build.php
 * writes into the zip), registered and enqueued as WordPress styles are and
 * printed by wp_print_styles(), and no script. The app shell (the manifest
 * and app.js, which registers a service worker) is not served, since
 * wp-admin is not where the dashboard is installed as an app, and the frame
 * headers allow wp-admin to frame it.
 */
final class AdminDashboard
{
    public const PAGE = 'cronwatch';
    public const NONCE = 'cronwatch_dashboard';
    /** The base path the dashboard is given, rewritten in every link. Nothing a page shows can end an attribute value with it, since text is escaped. */
    public const MARKER = '/__cronwatch_wp_admin__';
    /** The dashboard's stylesheet: its handle, and its file in the plugin. */
    public const STYLE = 'cronwatch-dashboard-page';
    public const STYLESHEET = 'css/dashboard.css';

    public static function url(string $path = '/'): string
    {
        return add_query_arg(['page' => self::PAGE, 'cw' => rawurlencode($path)], admin_url('admin.php'));
    }

    /** The dashboard's page for a job, for alert links. */
    public static function jobUrl(string $job): string
    {
        return add_query_arg(['page' => self::PAGE, 'job' => rawurlencode($job)], admin_url('admin.php'));
    }

    /** load-<hook>: a request for the dashboard itself (?cw=) is answered here, before wp-admin writes its page. */
    public static function load(): void
    {
        if (!isset($_GET['cw'])) { // phpcs:ignore WordPress.Security.NonceVerification.Recommended -- reading which page; changes are checked in serve().
            return;
        }
        $response = self::serve();
        self::send($response);
        exit;
    }

    /** The dashboard's answer to the request PHP is handling, rewritten for wp-admin. */
    public static function serve(): Response
    {
        if (!current_user_can('manage_options')) {
            wp_die(esc_html__('Sorry, you are not allowed to see this page.', 'cronwatch'), 403);
        }
        $server = wp_unslash($_SERVER);
        $method = strtoupper((string) ($server['REQUEST_METHOD'] ?? 'GET'));
        // The nonce WordPress asks of every change; the dashboard's own forms carry it (see rewrite()).
        if ($method !== 'GET' && $method !== 'HEAD') {
            $nonce = isset($_GET['_wpnonce']) ? sanitize_text_field(wp_unslash($_GET['_wpnonce'])) : '';
            if (!wp_verify_nonce($nonce, self::NONCE)) {
                wp_die(esc_html__('The link you followed has expired.', 'cronwatch'), 403);
            }
        }
        $path = isset($_GET['cw']) ? (string) wp_unslash($_GET['cw']) : '/'; // phpcs:ignore WordPress.Security.ValidatedSanitizedInput.InputNotSanitized -- a path the dashboard reads and escapes itself.
        if (!str_starts_with($path, '/')) {
            $path = '/' . $path;
        }
        $query = [];
        foreach (explode('&', (string) ($server['QUERY_STRING'] ?? '')) as $pair) {
            $name = urldecode(explode('=', $pair, 2)[0]);
            if ($pair !== '' && !in_array($name, ['page', 'cw', 'job', '_wpnonce'], true)) {
                $query[] = $pair;
            }
        }
        $globals = Request::fromGlobals($server, Request::readInput());
        $request = new Request($method, Request::normalizePath(self::MARKER . $path), implode('&', $query), $globals->headers, $globals->body(), $globals->origin);
        if ($method === 'POST' && ($path === '/check' || $path === '/api/check')) {
            // The plugin's check: WP-Cron's events declared as jobs first.
            Plugin::prepare();
        }
        $dashboard = new Dashboard(Plugin::client(), token: false, basePath: self::MARKER, origin: self::origin(admin_url()), empty: self::emptyBoard(), head: [self::class, 'head']);
        return self::rewrite($dashboard->handle($request));
    }

    /**
     * What the board says before anything is recorded, in place of the
     * library's line for developers (how to declare a job in code): the
     * site's WP-Cron events appear once the check has run.
     */
    public static function emptyBoard(): string
    {
        return sprintf(
            /* translators: %s: the WP-CLI command that runs the check, wp cronwatch check. */
            esc_html__('WP-Cron\'s events appear here after the first check, which runs every five minutes, and their runs as WP-Cron runs them. To see them now, press Run check now above, or run %s.', 'cronwatch'),
            '<code>wp cronwatch check</code>'
        );
    }

    /**
     * The head of the dashboard's pages, in place of the library's own (its
     * manifest, app.js and inline stylesheet): the stylesheet, registered,
     * enqueued and printed through WordPress's styles, and the icon.
     */
    public static function head(string $base): string
    {
        wp_register_style(self::STYLE, plugins_url(self::STYLESHEET, CRONWATCH_PLUGIN_FILE), [], \Cronwatch\Cronwatch::VERSION);
        wp_enqueue_style(self::STYLE);
        ob_start();
        wp_print_styles([self::STYLE]);
        return (string) ob_get_clean() . '<link rel="icon" href="' . esc_attr($base . '/icons/icon.svg') . "\" type=\"image/svg+xml\">\n";
    }

    /**
     * The CSP of the dashboard's pages in wp-admin: the library's, less what
     * the app shell needed (no script, manifest or worker), with the
     * stylesheet's origin ('self' unless the plugins are served from another,
     * WP_PLUGIN_URL), inline style attributes (the timeline places its marks
     * with them), and wp-admin as the one page that may frame it.
     */
    public static function csp(): string
    {
        $styles = "'self'";
        $origin = self::origin(plugins_url(self::STYLESHEET, CRONWATCH_PLUGIN_FILE));
        if ($origin !== null && $origin !== self::origin(admin_url())) {
            $styles .= " {$origin}";
        }
        return "default-src 'none'; style-src {$styles} 'unsafe-inline'; img-src 'self' data:; form-action 'self'; frame-ancestors 'self'; base-uri 'none'";
    }

    /** The origin of a URL of this site, for the dashboard's same-origin check. */
    public static function origin(string $url): ?string
    {
        $parts = wp_parse_url($url);
        if (!is_array($parts) || !isset($parts['scheme'], $parts['host'])) {
            return null;
        }
        return $parts['scheme'] . '://' . $parts['host'] . (isset($parts['port']) ? ':' . $parts['port'] : '');
    }

    /**
     * The dashboard's answer made to live in wp-admin: links, forms and
     * redirects under the marker point at admin.php?page=cronwatch&cw=<path>,
     * forms carry the nonce, and the pages' CSP is the plugin's (csp()).
     */
    public static function rewrite(Response $response): Response
    {
        $headers = $response->headers;
        if (isset($headers['location']) && str_starts_with($headers['location'], self::MARKER)) {
            $headers['location'] = self::url(substr($headers['location'], strlen(self::MARKER)) ?: '/');
        }
        if (isset($headers['x-frame-options'])) {
            $headers['x-frame-options'] = 'SAMEORIGIN';
        }
        if (isset($headers['content-security-policy'])) {
            $headers['content-security-policy'] = $headers['content-security-policy'] === Dashboard::CSP
                ? self::csp()
                : str_replace("frame-ancestors 'none'", "frame-ancestors 'self'", $headers['content-security-policy']);
        }
        $body = $response->body;
        if (str_starts_with((string) ($headers['content-type'] ?? ''), 'text/html')) {
            $marker = preg_quote(self::MARKER, '#');
            $body = (string) preg_replace_callback("#(\\s(?:href|action|src)=)\"{$marker}(/[^\"]*)\"#", function (array $m): string {
                $url = self::url(html_entity_decode($m[2], ENT_QUOTES));
                if (str_starts_with($m[1], ' action')) {
                    $url = add_query_arg('_wpnonce', wp_create_nonce(self::NONCE), $url);
                }
                return $m[1] . '"' . esc_url($url) . '"';
            }, $body);
        }
        return new Response($response->status, $headers, $body);
    }

    private static function send(Response $response): void
    {
        // wp-admin's own no-cache headers stand; the dashboard's replace any of the same name.
        $response->send();
    }

    /** The admin screen: the dashboard in a frame, opened at a job's page when an alert link names one. */
    public static function render(): void
    {
        if (!current_user_can('manage_options')) {
            wp_die(esc_html__('Sorry, you are not allowed to see this page.', 'cronwatch'), 403);
        }
        $job = isset($_GET['job']) ? sanitize_text_field(wp_unslash($_GET['job'])) : ''; // phpcs:ignore WordPress.Security.NonceVerification.Recommended -- only picks the page to open.
        $src = self::url($job === '' ? '/' : '/jobs/' . rawurlencode($job));
        echo '<div class="wrap cronwatch-dashboard"><h1 class="screen-reader-text">' . esc_html__('CronWatch', 'cronwatch') . '</h1>';
        echo '<p class="cronwatch-dashboard-links"><a href="' . esc_url(admin_url('admin.php?page=' . Admin::PAGE)) . '">' . esc_html__('Settings', 'cronwatch') . '</a> | '
            . '<a href="' . esc_url($src) . '" target="_blank" rel="noopener">' . esc_html__('Open on its own', 'cronwatch') . '</a></p>';
        echo '<iframe class="cronwatch-dashboard-frame" title="' . esc_attr__('CronWatch dashboard', 'cronwatch') . '" src="' . esc_url($src) . '"></iframe></div>';
    }

    /** admin_enqueue_scripts: the frame's size, on the dashboard's screen only. */
    public static function styles(string $hook): void
    {
        if (!str_ends_with($hook, '_page_' . self::PAGE)) {
            return;
        }
        wp_register_style('cronwatch-dashboard', false, [], \Cronwatch\Cronwatch::VERSION);
        wp_enqueue_style('cronwatch-dashboard');
        wp_add_inline_style('cronwatch-dashboard', '.cronwatch-dashboard{margin:10px 20px 0 2px}.cronwatch-dashboard-links{margin:0 0 8px;text-align:right}'
            . '.cronwatch-dashboard-frame{display:block;width:100%;height:calc(100vh - 150px);min-height:560px;border:1px solid #c3c4c7;background:#f4f4f5}');
    }
}
