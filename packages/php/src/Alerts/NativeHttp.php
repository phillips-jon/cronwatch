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
    private static ?self $default = null;

    private readonly bool $curl;

    /** @param bool|null $curl true or false to choose; null for curl when it is loaded */
    public function __construct(?bool $curl = null)
    {
        $this->curl = $curl ?? extension_loaded('curl');
        if ($this->curl && !extension_loaded('curl')) {
            throw new \LogicException('NativeHttp(curl: true) needs the curl extension');
        }
    }

    /** One shared instance, for channels given no `http:`. */
    public static function default(): self
    {
        return self::$default ??= new self();
    }

    public function post(string $url, string $body, array $headers, int $timeoutMs = self::TIMEOUT_MS): HttpResponse
    {
        $lines = [];
        foreach ($headers as $name => $value) {
            $lines[] = $name . ': ' . self::headerValue((string) $value);
        }
        return $this->curl ? $this->viaCurl($url, $body, $lines, $timeoutMs) : $this->viaStreams($url, $body, $lines, $timeoutMs);
    }

    /** A header value without the spaces, tabs and line breaks around it, as fetch sends it; one with a line break inside is refused, as fetch refuses it. */
    public static function headerValue(string $value): string
    {
        $value = trim($value, " \t\r\n");
        if (strpbrk($value, "\r\n\0") !== false) {
            throw new \InvalidArgumentException('a header value may not contain a line break');
        }
        return $value;
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
            CURLOPT_WRITEFUNCTION => function ($handle, string $chunk) use (&$received): int {
                $received .= $chunk;
                return strlen($chunk);
            },
        ]);
        $done = curl_exec($handle);
        $errno = curl_errno($handle);
        $error = curl_error($handle);
        if ($done === true && $errno === 0) {
            return new HttpResponse($status, $received);
        }
        if ($errno === CURLE_OPERATION_TIMEDOUT) {
            if ($status >= 200) {
                return new HttpResponse($status, '');
            }
            throw new RequestTimeout();
        }
        throw new \RuntimeException($error !== '' ? $error : "curl error {$errno}");
    }

    /** @param list<string> $lines */
    private function viaStreams(string $url, string $body, array $lines, int $timeoutMs): HttpResponse
    {
        if (!filter_var(ini_get('allow_url_fopen'), FILTER_VALIDATE_BOOLEAN)) {
            throw new \LogicException('sending alerts needs the curl extension or allow_url_fopen');
        }
        $scheme = strtolower((string) parse_url($url, PHP_URL_SCHEME));
        if ($scheme !== 'http' && $scheme !== 'https') {
            throw new \InvalidArgumentException('only http and https URLs can be posted to');
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
            while (!feof($stream)) {
                $left = $deadline - hrtime(true) / 1e9;
                if ($left <= 0) {
                    return new HttpResponse($status, '');
                }
                stream_set_timeout($stream, (int) floor($left), (int) (fmod($left, 1) * 1e6));
                $chunk = fread($stream, 65536);
                if ($chunk === false || stream_get_meta_data($stream)['timed_out']) {
                    return new HttpResponse($status, '');
                }
                $received .= $chunk;
            }
            return new HttpResponse($status, $received);
        } finally {
            fclose($stream);
        }
    }
}
