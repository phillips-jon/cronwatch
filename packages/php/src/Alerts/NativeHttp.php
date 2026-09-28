<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

/**
 * The default Http: ext-curl when it is loaded, PHP's own http:// and
 * https:// streams otherwise, so no extension is required. Either way no
 * redirect is followed and the whole request (connecting, sending and
 * reading the answer) has one deadline. Past it before an answer it throws
 * RequestTimeout; past it while the body is still arriving it returns the
 * answer with an empty body.
 */
final class NativeHttp implements Http
{
    private readonly bool $curl;

    /** @param bool|null $curl true or false to choose; null for curl when it is loaded */
    public function __construct(?bool $curl = null)
    {
        $this->curl = $curl ?? extension_loaded('curl');
        if ($this->curl && !extension_loaded('curl')) {
            throw new \LogicException('NativeHttp(curl: true) needs the curl extension');
        }
    }

    public function post(string $url, string $body, array $headers, int $timeoutMs = self::TIMEOUT_MS): HttpResponse
    {
        // Refused before curl or a stream sees it, and never quoted: a webhook URL's path is its credential.
        $url = Shared::postable($url);
        $lines = [];
        foreach (Shared::headers($headers) as $name => $value) {
            $lines[] = "{$name}: {$value}";
        }
        return $this->curl ? $this->viaCurl($url, $body, $lines, $timeoutMs) : $this->viaStreams($url, $body, $lines, $timeoutMs);
    }

    /** A header value as fetch sends it (see Shared::headerValue()). */
    public static function headerValue(string $value): string
    {
        return Shared::headerValue($value);
    }

    /** @param list<string> $lines */
    private function viaCurl(string $url, string $body, array $lines, int $timeoutMs): HttpResponse
    {
        $status = 0;
        $received = '';
        $handle = curl_init();
        curl_setopt_array($handle, [
            CURLOPT_URL => $url,
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => $body,
            // No "Expect: 100-continue" wait before a large body.
            CURLOPT_HTTPHEADER => [...$lines, 'Expect:'],
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_PROTOCOLS => CURLPROTO_HTTP | CURLPROTO_HTTPS,
            CURLOPT_TIMEOUT_MS => max(1, $timeoutMs),
            CURLOPT_CONNECTTIMEOUT_MS => max(1, $timeoutMs),
            CURLOPT_NOSIGNAL => true,
            // Accept what curl can decode, and decode it, as fetch does.
            CURLOPT_ENCODING => '',
            CURLOPT_HEADERFUNCTION => function ($handle, string $line) use (&$status): int {
                if (preg_match('/^HTTP\/[0-9.]+ ([0-9]{3})/', $line, $m) === 1) {
                    $status = (int) $m[1];
                }
                return strlen($line);
            },
            CURLOPT_WRITEFUNCTION => function ($handle, string $chunk) use (&$received, &$full): int {
                $received .= substr($chunk, 0, max(0, self::MAX_BODY - strlen($received)));
                if (strlen($received) >= self::MAX_BODY) {
                    // Enough: stop reading (curl answers CURLE_WRITE_ERROR).
                    $full = true;
                    return 0;
                }
                return strlen($chunk);
            },
        ]);
        $full = false;
        $done = curl_exec($handle);
        $errno = curl_errno($handle);
        $error = curl_error($handle);
        if (($done === true && $errno === 0) || ($full && $errno === CURLE_WRITE_ERROR)) {
            return new HttpResponse($status, $received);
        }
        if ($errno === CURLE_OPERATION_TIMEDOUT) {
            if ($status >= 200) {
                return new HttpResponse($status, '');
            }
            throw new RequestTimeout();
        }
        throw new \RuntimeException(Shared::scrub($error !== '' ? $error : "curl error {$errno}", $url));
    }

    /** @param list<string> $lines */
    private function viaStreams(string $url, string $body, array $lines, int $timeoutMs): HttpResponse
    {
        if (!filter_var(ini_get('allow_url_fopen'), FILTER_VALIDATE_BOOLEAN)) {
            throw new \LogicException('sending alerts needs the curl extension or allow_url_fopen');
        }
        $deadline = hrtime(true) / 1e9 + $timeoutMs / 1000;
        $context = stream_context_create([
            'http' => [
                'method' => 'POST',
                'header' => implode("\r\n", [...$lines, 'Connection: close']),
                'content' => $body,
                'follow_location' => 0,
                'ignore_errors' => true,
                'timeout' => max(0.001, $timeoutMs / 1000),
                'protocol_version' => 1.1,
            ],
        ]);
        error_clear_last();
        $stream = @fopen($url, 'rb', false, $context);
        if ($stream === false) {
            $message = error_get_last()['message'] ?? 'the request failed';
            if (stripos($message, 'timed out') !== false || hrtime(true) / 1e9 >= $deadline) {
                throw new RequestTimeout();
            }
            // The warning starts "fopen(<url>): "; only the origin may show.
            $message = Shared::scrub($message, $url);
            throw new \RuntimeException(preg_replace('/^fopen\([^)]*\): /', '', $message) ?? $message);
        }
        try {
            $status = 0;
            foreach (stream_get_meta_data($stream)['wrapper_data'] ?? [] as $line) {
                if (is_string($line) && preg_match('/^HTTP\/[0-9.]+ ([0-9]{3})/', $line, $m) === 1) {
                    $status = (int) $m[1];
                }
            }
            $received = '';
            while (!feof($stream) && strlen($received) < self::MAX_BODY) {
                $left = $deadline - hrtime(true) / 1e9;
                if ($left <= 0) {
                    return new HttpResponse($status, '');
                }
                stream_set_timeout($stream, (int) floor($left), (int) (fmod($left, 1) * 1e6));
                $chunk = fread($stream, 65536);
                if ($chunk === false || stream_get_meta_data($stream)['timed_out']) {
                    return new HttpResponse($status, '');
                }
                $received .= substr($chunk, 0, self::MAX_BODY - strlen($received));
            }
            return new HttpResponse($status, $received);
        } finally {
            fclose($stream);
        }
    }
}
