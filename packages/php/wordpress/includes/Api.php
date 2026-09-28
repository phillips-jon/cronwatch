<?php

declare(strict_types=1);

namespace Cronwatch\WordPress;

\defined('ABSPATH') || exit;

use Cronwatch\Web\Dashboard;
use Cronwatch\Web\Request;
use Cronwatch\Web\Response;

/**
 * The library's JSON API (the dashboard's /api routes, which @cronwatch/mcp
 * speaks) as a REST route of the site, off until the owner turns it on with
 * a token under CronWatch, Settings. Nothing is registered while it is off,
 * so the site answers 404 as it would to any unknown route. Only the /api
 * paths are there: the dashboard's pages stay in wp-admin.
 *
 * The route is cronwatch/v1/api/..., so the base URL to give the MCP server
 * is rest_url('cronwatch/v1') (https://example.com/wp-json/cronwatch/v1, or
 * https://example.com/?rest_route=/cronwatch/v1 without pretty permalinks).
 * A request needs `Authorization: Bearer <token>`; the dashboard checks it,
 * and answers with the SDK's JSON, status and headers, byte for byte, which
 * the plugin writes itself rather than letting the REST server encode it
 * again. WordPress's own REST headers (Link, the CORS headers) stay.
 */
final class Api
{
    public const NAMESPACE = 'cronwatch/v1';

    /** The response the route made, written out by serve(). */
    private static ?Response $pending = null;

    /** rest_api_init: registers the route when the owner has turned the API on. */
    public static function register(): void
    {
        if (!self::enabled()) {
            return;
        }
        register_rest_route(self::NAMESPACE, '/api(?:/(?P<path>.*))?', [
            'methods' => ['GET', 'POST', 'DELETE'],
            'callback' => [self::class, 'handle'],
            'permission_callback' => [self::class, 'permission'],
            'args' => [],
        ]);
    }

    /** On, with a token saved. */
    public static function enabled(?array $settings = null): bool
    {
        $settings ??= Plugin::settings();
        return $settings['api_enabled'] === '1' && $settings['api_token'] !== '';
    }

    /** The base URL an API client (the MCP server) is given. */
    public static function baseUrl(): string
    {
        return untrailingslashit(rest_url(self::NAMESPACE));
    }

    /**
     * The route is open to the REST server: the dashboard checks the bearer
     * token itself, as it does wherever the library is mounted, and answers
     * 401 without it. The route exists only while the owner has it on.
     */
    public static function permission(): bool
    {
        return self::enabled();
    }

    /** The route's callback: the request handed to the library's dashboard. */
    public static function handle(\WP_REST_Request $rest): \WP_REST_Response
    {
        $settings = Plugin::settings();
        $path = '/' . ltrim((string) ($rest->get_param('path') ?? ''), '/');
        $headers = [];
        foreach ($rest->get_headers() as $name => $values) {
            $headers[str_replace('_', '-', (string) $name)] = implode(', ', (array) $values);
        }
        $query = http_build_query(array_diff_key($rest->get_query_params(), ['rest_route' => true]), '', '&', PHP_QUERY_RFC3986);
        $base = '/' . self::NAMESPACE;
        $request = new Request($rest->get_method(), Request::normalizePath($base . '/api' . ($path === '/' ? '' : $path)), $query, $headers, (string) $rest->get_body(), (string) AdminDashboard::origin(home_url()));
        if (in_array($rest->get_method(), ['GET', 'POST'], true) && $path === '/check') {
            // The plugin's check: WP-Cron's events declared as jobs first.
            Plugin::prepare();
        }
        $dashboard = new Dashboard(Plugin::client(), token: $settings['api_token'], basePath: $base, origin: AdminDashboard::origin(rest_url()));
        self::$pending = $dashboard->handle($request);
        return new \WP_REST_Response(null, self::$pending->status, self::$pending->headers);
    }

    /**
     * rest_pre_serve_request: writes the dashboard's own body, so the JSON is
     * the SDK's bytes, not the REST server's encoding of it.
     */
    public static function serve(mixed $served): mixed
    {
        if (self::$pending === null || $served) {
            return $served;
        }
        $response = self::$pending;
        self::$pending = null;
        if (!headers_sent()) {
            foreach ($response->headers as $name => $value) {
                header("{$name}: {$value}", true);
            }
        }
        echo $response->body; // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped -- JSON written by the library, not HTML.
        return true;
    }
}
