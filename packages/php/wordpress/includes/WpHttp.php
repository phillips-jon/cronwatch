<?php

declare(strict_types=1);

namespace Cronwatch\WordPress;

\defined('ABSPATH') || exit;

use Cronwatch\Alerts\Http;
use Cronwatch\Alerts\HttpResponse;
use Cronwatch\Alerts\RequestTimeout;

/**
 * The library's Http on WordPress's HTTP API (wp_remote_post), which the
 * plugin directory asks plugins to use, so a site's proxy settings and
 * http_request_args filters apply. No redirect is followed (redirection 0):
 * a 3xx is an answer like any other outside 2xx, as the SDK's fetch with
 * redirect: "error" has it.
 */
final class WpHttp implements Http
{
    public function post(string $url, string $body, array $headers, int $timeoutMs = self::TIMEOUT_MS): HttpResponse
    {
        $response = wp_remote_post($url, [
            'body' => $body,
            'headers' => array_map(fn ($value) => trim((string) $value, " \t\r\n"), $headers),
            'timeout' => max(1, $timeoutMs / 1000),
            'redirection' => 0,
        ]);
        if (is_wp_error($response)) {
            $message = $response->get_error_message();
            if (stripos($message, 'timed out') !== false || stripos($message, 'timeout') !== false) {
                throw new RequestTimeout();
            }
            throw new \RuntimeException($message);
        }
        return new HttpResponse((int) wp_remote_retrieve_response_code($response), (string) wp_remote_retrieve_body($response));
    }
}
