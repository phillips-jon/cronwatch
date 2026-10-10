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
 * A request needs `Authorization: Bearer <token>`, which the route's
 * permission callback checks (in constant time) before anything else runs;
 * the dashboard then answers with the SDK's JSON, status, and headers, byte
 * for byte, which the plugin writes itself rather than letting the REST
 * server encode it again. WordPress's own REST headers (Link, the CORS
 * headers) stay.
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
     * The route's permission check: `Authorization: Bearer <token>`, the
     * owner's token compared in constant time (or, for /api/check, the
     * client's cron secret, when a developer gave it one). Missing or wrong,
     * it is a 401 whose body is the dashboard's own
     * (`{"ok":false,"error":"Unauthorized"}`, what @cronwatch/mcp reads),
     * written by serve(). With the API off it is the REST server's 404.
     */
    public static function permission(\WP_REST_Request $rest): bool|\WP_Error
    {
        $settings = Plugin::settings();
        if (!self::enabled($settings)) {
            return new \WP_Error('rest_no_route', __('No route was found matching the URL and request method.', 'cronwatch'), ['status' => 404]);
        }
        $bearer = self::bearer((string) $rest->get_header('authorization'));
        if ($bearer !== null) {
            if (hash_equals((string) $settings['api_token'], $bearer)) {
                return true;
            }
            $secret = Plugin::client()->cronSecret;
            if ($secret !== null && self::path($rest) === '/check' && hash_equals($secret, $bearer)) {
                return true;
            }
        }
        // The dashboard's own refusal of this request, its credentials taken
        // out: the SDK's 401 (or its 403 for a cross-site change), body, and headers.
        $refusal = self::dashboard($settings)->handle(self::request($rest, false));
        if ($refusal->status < 400) {
            $refusal = new Response(401, ['content-type' => 'application/json; charset=utf-8', 'cache-control' => 'no-store'] + Dashboard::SECURITY_HEADERS, '{"ok":false,"error":"Unauthorized"}');
        }
        self::$pending = $refusal;
        $error = json_decode($refusal->body, true);
        return new \WP_Error('cronwatch_unauthorized', is_array($error) && is_string($error['error'] ?? null) ? $error['error'] : 'Unauthorized', ['status' => $refusal->status]);
    }

    /** The route's callback, once the permission check passed: the request handed to the library's dashboard. */
    public static function handle(\WP_REST_Request $rest): \WP_REST_Response
    {
        $settings = Plugin::settings();
        $path = self::path($rest);
        if ($path === null) {
            // A path that leaves /api (dot segments): the dashboard's pages stay in wp-admin.
            self::$pending = new Response(404, ['content-type' => 'application/json; charset=utf-8', 'cache-control' => 'no-store'] + Dashboard::SECURITY_HEADERS, '{"ok":false,"error":"Not found"}');
            return new \WP_REST_Response(null, 404, self::$pending->headers);
        }
        if (in_array($rest->get_method(), ['GET', 'POST'], true) && $path === '/check') {
            // The plugin's check: WP-Cron's events declared as jobs first.
            Plugin::prepare();
        }
        self::$pending = self::dashboard($settings)->handle(self::request($rest, true));
        return new \WP_REST_Response(null, self::$pending->status, self::$pending->headers);
    }

    private static function dashboard(array $settings): Dashboard
    {
        return new Dashboard(Plugin::client(), token: (string) $settings['api_token'], basePath: '/' . self::NAMESPACE, origin: AdminDashboard::origin(rest_url()), head: [AdminDashboard::class, 'head']);
    }

    /** The token of `Bearer <token>`, as the dashboard reads it, or null for anything else. */
    private static function bearer(string $authorization): ?string
    {
        return preg_match('/^Bearer[\t\n\x0B\f\r ]+(.*)$/is', $authorization, $m) === 1 && $m[1] !== '' ? $m[1] : null;
    }

    /**
     * The path under /api as the dashboard is to read it ("/jobs/wp%3Ax"),
     * or null for one that leaves /api. WordPress has already decoded the
     * route once, so each segment is encoded again: the dashboard decodes
     * it, and a "%2e%2e" is never decoded twice into "..".
     */
    private static function path(\WP_REST_Request $rest): ?string
    {
        $segments = explode('/', trim((string) ($rest->get_param('path') ?? ''), '/'));
        foreach ($segments as $segment) {
            if ($segment === '.' || $segment === '..') {
                return null;
            }
        }
        $path = '/' . implode('/', array_map('rawurlencode', $segments));
        return $path === '/' ? '' : $path;
    }

    /** The REST request as the dashboard's, with or without its credentials. */
    private static function request(\WP_REST_Request $rest, bool $credentials): Request
    {
        $headers = [];
        foreach ($rest->get_headers() as $name => $values) {
            $name = strtolower(str_replace('_', '-', (string) $name));
            if (!$credentials && ($name === 'authorization' || $name === 'cookie')) {
                continue;
            }
            $headers[$name] = implode(', ', (array) $values);
        }
        $query = http_build_query(array_diff_key($rest->get_query_params(), ['rest_route' => true]), '', '&', PHP_QUERY_RFC3986);
        $base = '/' . self::NAMESPACE;
        return new Request($rest->get_method(), $base . '/api' . (self::path($rest) ?? ''), $query, $headers, (string) $rest->get_body(), (string) AdminDashboard::origin(home_url()));
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
