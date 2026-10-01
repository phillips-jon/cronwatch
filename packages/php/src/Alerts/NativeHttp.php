<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

/**
 * The default Http: ext-curl when it is loaded, a socket of its own
 * otherwise (PHP's stream sockets, TLS through OpenSSL), so no extension is
 * required. Either way no redirect is followed and the whole request
 * (connecting, the TLS handshake, sending, and reading the answer, its
 * headers included) has one deadline. Past it before an answer it throws
 * RequestTimeout; past it while the body is still arriving it returns the
 * answer with an empty body.
 *
 * The URL, the body and the headers are marked #[\SensitiveParameter]: a
 * webhook URL's path, an API key in a header or a body is a credential, and
 * an exception's trace (which an error tracker shows) would otherwise hold
 * them.
 *
 * @internal
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

    public function post(#[\SensitiveParameter] string $url, #[\SensitiveParameter] string $body, #[\SensitiveParameter] array $headers, int $timeoutMs = self::TIMEOUT_MS): HttpResponse
    {
        // Refused before curl or a socket sees it, and never quoted: a webhook URL's path is its credential.
        $url = Shared::postable($url);
        $lines = [];
        foreach (Shared::headers($headers) as $name => $value) {
            $lines[] = "{$name}: {$value}";
        }
        return $this->curl ? $this->viaCurl($url, $body, $lines, $timeoutMs) : $this->viaSocket($url, $body, $lines, $timeoutMs);
    }

    /** A header value as fetch sends it (see Shared::headerValue()). */
    public static function headerValue(#[\SensitiveParameter] string $value): string
    {
        return Shared::headerValue($value);
    }

    /** @param list<string> $lines */
    private function viaCurl(#[\SensitiveParameter] string $url, #[\SensitiveParameter] string $body, #[\SensitiveParameter] array $lines, int $timeoutMs): HttpResponse
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

    /**
     * The request over a socket of its own, every step under the one
     * deadline: PHP's http:// stream reads the answer's headers before it
     * returns, with its timeout applying to each read, so a server that sent
     * a header line every half second could hold it open for ever.
     *
     * @param list<string> $lines
     */
    private function viaSocket(#[\SensitiveParameter] string $url, #[\SensitiveParameter] string $body, #[\SensitiveParameter] array $lines, int $timeoutMs): HttpResponse
    {
        $deadline = hrtime(true) / 1e9 + $timeoutMs / 1000;
        // phpcs:ignore WordPress.WP.AlternativeFunctions.parse_url_parse_url -- a library that runs outside WordPress too.
        $parts = parse_url($url);
        if (!is_array($parts) || !isset($parts['host'])) {
            throw new \InvalidArgumentException('only http and https URLs can be posted to, not this URL');
        }
        $https = strtolower($parts['scheme'] ?? '') === 'https';
        $host = $parts['host'];
        $port = $parts['port'] ?? ($https ? 443 : 80);
        $target = ($parts['path'] ?? '') === '' ? '/' : $parts['path'];
        if (isset($parts['query'])) {
            $target .= "?{$parts['query']}";
        }
        $head = ["POST {$target} HTTP/1.1", 'Host: ' . $host . ($port === ($https ? 443 : 80) ? '' : ":{$port}")];
        $given = array_map(fn (string $line) => strtolower(substr($line, 0, (int) strpos($line, ':'))), $lines);
        if (isset($parts['user']) && !in_array('authorization', $given, true)) {
            // Credentials in the URL, as PHP's http:// stream and curl send them.
            $head[] = 'Authorization: ' . Shared::basicAuth(rawurldecode($parts['user']), rawurldecode($parts['pass'] ?? ''));
        }
        $head = [...$head, ...$lines, 'Content-Length: ' . strlen($body), 'Connection: close'];
        $request = implode("\r\n", $head) . "\r\n\r\n" . $body;

        $socket = $this->connect($host, $port, $https, $deadline, $url);
        try {
            self::send($socket, $request, $deadline, $url);
            return self::receive($socket, $deadline, $url);
        } finally {
            fclose($socket);
        }
    }

    /** Seconds left before the deadline. */
    private static function left(float $deadline): float
    {
        return $deadline - hrtime(true) / 1e9;
    }

    /**
     * Waits until the socket can be read (or written) or the deadline passes.
     *
     * @param resource $socket
     */
    private static function wait($socket, bool $write, float $deadline): bool
    {
        $left = self::left($deadline);
        if ($left <= 0) {
            return false;
        }
        $read = $write ? [] : [$socket];
        $writes = $write ? [$socket] : [];
        $except = [];
        $ready = @stream_select($read, $writes, $except, (int) floor($left), (int) (fmod($left, 1) * 1e6));
        return $ready !== false && self::left($deadline) > 0;
    }

    /** @return resource a connected socket, TLS set up for https */
    private function connect(string $host, int $port, bool $https, float $deadline, #[\SensitiveParameter] string $url)
    {
        $name = trim($host, '[]');
        $context = stream_context_create(['ssl' => [
            'peer_name' => $name,
            'verify_peer' => true,
            'verify_peer_name' => true,
            'SNI_enabled' => true,
        ]]);
        $errno = 0;
        $error = '';
        $socket = @stream_socket_client("tcp://{$host}:{$port}", $errno, $error, max(0.001, self::left($deadline)), STREAM_CLIENT_CONNECT, $context);
        if ($socket === false) {
            if (self::left($deadline) <= 0 || stripos($error, 'timed out') !== false) {
                throw new RequestTimeout();
            }
            throw new \RuntimeException(Shared::scrub($error !== '' ? $error : "could not connect ({$errno})", $url));
        }
        stream_set_blocking($socket, false);
        if (!$https) {
            return $socket;
        }
        while (true) {
            error_clear_last();
            $done = @stream_socket_enable_crypto($socket, true, STREAM_CRYPTO_METHOD_TLS_CLIENT);
            if ($done === true) {
                return $socket;
            }
            if ($done === false) {
                fclose($socket);
                $message = error_get_last()['message'] ?? 'the TLS handshake failed';
                throw new \RuntimeException(Shared::scrub((string) preg_replace('/^stream_socket_enable_crypto\(\): /', '', $message), $url));
            }
            if (!self::wait($socket, false, $deadline)) {
                fclose($socket);
                throw new RequestTimeout();
            }
        }
    }

    /** @param resource $socket */
    private static function send($socket, #[\SensitiveParameter] string $request, float $deadline, #[\SensitiveParameter] string $url): void
    {
        $sent = 0;
        $size = strlen($request);
        while ($sent < $size) {
            error_clear_last();
            $n = @fwrite($socket, substr($request, $sent, 65536));
            if ($n === false) {
                throw new \RuntimeException(Shared::scrub(error_get_last()['message'] ?? 'the request could not be sent', $url));
            }
            $sent += $n;
            if ($sent < $size && $n === 0 && !self::wait($socket, true, $deadline)) {
                throw new RequestTimeout();
            }
        }
    }

    /** How many informational (1xx) answers are skipped before the real one; past it the server is not answering. */
    private const MAX_INFORMATIONAL = 16;

    /** The longest chunk-size line read (its size, extensions and all); a longer one is not a chunked body. */
    private const MAX_CHUNK_LINE = 4096;

    /**
     * The answer: its status once the headers are in (skipping any 1xx, up
     * to MAX_INFORMATIONAL of them), and its body, de-chunked as it arrives,
     * at most MAX_BODY bytes of it. Every read is under the deadline, however
     * fast the bytes come, and nothing read is kept past what the body needs.
     *
     * @param resource $socket
     */
    private static function receive($socket, float $deadline, #[\SensitiveParameter] string $url): HttpResponse
    {
        $buffer = '';
        $status = 0;
        $headers = [];
        $informational = 0;
        // The headers: past the deadline before they are all in, no answer came.
        while (true) {
            $end = strpos($buffer, "\r\n\r\n");
            if ($end !== false) {
                $block = explode("\r\n", substr($buffer, 0, $end));
                $buffer = substr($buffer, $end + 4);
                if (preg_match('/^HTTP\/[0-9.]+ ([0-9]{3})/', $block[0], $m) !== 1) {
                    throw new \RuntimeException('the server did not answer with HTTP');
                }
                $status = (int) $m[1];
                if ($status >= 100 && $status < 200) {
                    if (++$informational > self::MAX_INFORMATIONAL) {
                        throw new \RuntimeException('the server sent informational answers and no answer');
                    }
                    continue;
                }
                foreach (array_slice($block, 1) as $line) {
                    $colon = strpos($line, ':');
                    if ($colon !== false) {
                        $headers[strtolower(trim(substr($line, 0, $colon)))] = trim(substr($line, $colon + 1));
                    }
                }
                break;
            }
            if (strlen($buffer) > 256 * 1024) {
                throw new \RuntimeException('the answer\'s headers were too long');
            }
            $chunk = self::read($socket, $deadline);
            if ($chunk === null) {
                throw new RequestTimeout();
            }
            if ($chunk === '') {
                throw new \RuntimeException(Shared::scrub('the server closed the connection without an answer', $url));
            }
            $buffer .= $chunk;
        }
        $chunked = str_contains(strtolower($headers['transfer-encoding'] ?? ''), 'chunked');
        $length = !$chunked && isset($headers['content-length']) && ctype_digit($headers['content-length']) ? (int) $headers['content-length'] : null;
        // The body: past the deadline while it arrives, the answer stands with an empty body.
        $body = '';
        // For a chunked body: the bytes left of the chunk being read, or null while a size line is.
        $need = null;
        while (true) {
            if ($chunked) {
                $complete = self::dechunk($buffer, $body, $need);
            } else {
                $body .= $buffer;
                $buffer = '';
                $complete = $length !== null && strlen($body) >= $length;
            }
            if ($complete || strlen($body) >= self::MAX_BODY) {
                return new HttpResponse($status, substr($length !== null ? substr($body, 0, $length) : $body, 0, self::MAX_BODY));
            }
            $chunk = self::read($socket, $deadline);
            if ($chunk === null) {
                return new HttpResponse($status, '');
            }
            if ($chunk === '') {
                return new HttpResponse($status, substr($body, 0, self::MAX_BODY));
            }
            $buffer .= $chunk;
        }
    }

    /**
     * The next bytes: a string, '' at the end of the stream, or null when the
     * deadline passed first, which is looked at before every read, so a peer
     * that never stops sending is cut off at it too.
     *
     * @param resource $socket
     */
    private static function read($socket, float $deadline): ?string
    {
        while (true) {
            if (self::left($deadline) <= 0) {
                return null;
            }
            $chunk = @fread($socket, 65536);
            if (is_string($chunk) && $chunk !== '') {
                return $chunk;
            }
            if ($chunk === false || feof($socket)) {
                return '';
            }
            if (!self::wait($socket, false, $deadline)) {
                return null;
            }
        }
    }

    /**
     * Decodes what has arrived of a chunked body into $out, taking it from
     * $raw, so each byte is looked at once and only an unfinished size line
     * is kept. $need is the bytes left of the chunk being read (its CRLF
     * included), or null while a size line is. Returns whether the body
     * ended: at its last chunk, or at a size line that is not one (not hex,
     * or longer than MAX_CHUNK_LINE without its end), where what came before
     * stands.
     */
    private static function dechunk(string &$raw, string &$out, ?int &$need): bool
    {
        while (true) {
            if ($need !== null) {
                $take = min($need, strlen($raw));
                // The chunk's data, without the CRLF that ends it.
                $out .= substr($raw, 0, max(0, min($take, $need - 2)));
                $raw = substr($raw, $take);
                $need -= $take;
                if ($need > 0) {
                    return false;
                }
                $need = null;
            }
            $eol = strpos($raw, "\r\n");
            if ($eol === false) {
                return strlen($raw) > self::MAX_CHUNK_LINE;
            }
            if ($eol > self::MAX_CHUNK_LINE) {
                return true;
            }
            $hex = trim(explode(';', substr($raw, 0, $eol))[0]);
            $raw = substr($raw, $eol + 2);
            if ($hex === '' || !ctype_xdigit($hex) || strlen(ltrim($hex, '0')) > 15) {
                return true;
            }
            $size = (int) hexdec($hex);
            if ($size === 0) {
                return true;
            }
            $need = $size + 2;
        }
    }
}
