<?php

declare(strict_types=1);

namespace Cronwatch\WordPress;

\defined('ABSPATH') || exit;

use Cronwatch\Alerts\Http;
use Cronwatch\Alerts\HttpResponse;
use Cronwatch\Alerts\RequestTimeout;
use Cronwatch\Alerts\Shared;

/**
 * The library's Http on WordPress's HTTP API (wp_remote_post), which the
 * plugin directory asks plugins to use, so a site's proxy settings and
 * http_request_args filters apply. The plugin makes it the default for
 * every channel (Transport::set()), so its zip carries no curl code of its
 * own. No redirect is followed (redirection 0): a 3xx is an answer like any
 * other outside 2xx, as the SDK's fetch with redirect: "error" has it. A URL
 * that is not http or https is refused before WordPress sees it, and an
 * error names only the URL's origin, since a webhook URL's path is its
 * credential.
 */
final class WpHttp implements Http
{
    public function post(string $url, string $body, array $headers, int $timeoutMs = self::TIMEOUT_MS): HttpResponse
    {
        $url = Shared::postable($url);
        $response = wp_remote_post($url, [
            'body' => $body,
            'headers' => Shared::headers($headers),
            'timeout' => max(1, $timeoutMs / 1000),
            'redirection' => 0,
            'limit_response_size' => Http::MAX_BODY,
            // On a network, where a site's administrators may not be the
            // network's, an alert URL may not reach a private address or an
            // unusual port (wp_safe_remote_post's rule); a filter can say otherwise.
            'reject_unsafe_urls' => (bool) apply_filters('cronwatch_reject_unsafe_urls', is_multisite(), Shared::origin($url)),
        ]);
        if (is_wp_error($response)) {
            $message = Shared::scrub($response->get_error_message(), $url);
            if (stripos($message, 'timed out') !== false || stripos($message, 'timeout') !== false) {
                throw new RequestTimeout();
            }
            throw new \RuntimeException(esc_html($message));
        }
        return new HttpResponse((int) wp_remote_retrieve_response_code($response), (string) wp_remote_retrieve_body($response));
    }
}
