<?php

declare(strict_types=1);

namespace Cronwatch\Web;

use Cronwatch\Js;

/**
 * What the dashboard reads of a request, in the shape of a fetch Request:
 * the method, the path as the browser sent it (percent-encoded, the mount
 * point included, dot segments resolved as the URL parser resolves them),
 * the raw query, the headers (lowercase names), the body, and the origin of
 * the request's own URL. Made from PHP's superglobals (fromGlobals), from a
 * PSR-7 ServerRequestInterface (fromPsr, duck typed, so psr/http-message is
 * not required), or by hand (create).
 */
final class Request
{
    /** @var array<string, string> */
    public readonly array $headers;
    private string|\Closure $body;

    /**
     * @param string $path the path as sent, still percent-encoded, mount point included
     * @param string $query the query string, without the "?", as sent
     * @param array<string, string> $headers any case; read case-insensitively
     * @param string|\Closure(): string $body the body's bytes, or a function that reads them (called at most once)
     * @param string $origin the origin of the request's own URL (scheme://host[:port])
     * @param string|null $mount where the server mounted the script (a path-info URL's SCRIPT_NAME), the default base path
     * @param array<string, mixed>|null $form fields the server already parsed from the body (PHP reads multipart bodies itself)
     */
    public function __construct(
        public readonly string $method,
        public readonly string $path,
        public readonly string $query = '',
        array $headers = [],
        string|\Closure $body = '',
        public readonly string $origin = 'http://localhost',
        public readonly ?string $mount = null,
        public readonly ?array $form = null,
    ) {
        $normalized = [];
        foreach ($headers as $name => $value) {
            $normalized[strtolower((string) $name)] = trim(is_array($value) ? implode(', ', $value) : (string) $value, " \t\r\n");
        }
        $this->headers = $normalized;
        $this->body = $body;
    }

    /**
     * A request for a URL, as a test or a script makes one:
     * Request::create('GET', 'https://app.example.com/cronwatch/api/jobs', ['authorization' => 'Bearer ...']).
     * A path alone is on http://localhost.
     *
     * @param array<string, string> $headers
     */
    public static function create(string $method, string $url, array $headers = [], string $body = '', ?string $mount = null): self
    {
        if (preg_match('#^([A-Za-z][A-Za-z0-9+.\-]*)://([^/?\#]*)(.*)$#Ds', $url, $m) === 1) {
            $origin = self::originOf($m[1], $m[2]);
            $target = $m[3];
        } else {
            $origin = 'http://localhost';
            $target = $url;
        }
        $target = explode('#', $target, 2)[0];
        [$path, $query] = array_pad(explode('?', $target, 2), 2, '');
        return new self($method, self::normalizePath($path), $query, $headers, $body, $origin, $mount);
    }

    /**
     * The request PHP is answering, from $_SERVER (or the array given), with
     * the body from php://input, or from $_POST and $_FILES for a multipart
     * form, which PHP reads itself and leaves php://input empty.
     *
     * @param array<string, mixed>|null $server
     * @param string|null $input the body, when it is not to be read from php://input
     */
    public static function fromGlobals(?array $server = null, ?string $input = null): self
    {
        $server ??= $_SERVER;
        $scheme = (!empty($server['HTTPS']) && strtolower((string) $server['HTTPS']) !== 'off') ? 'https' : strtolower((string) ($server['REQUEST_SCHEME'] ?? 'http'));
        $host = (string) ($server['HTTP_HOST'] ?? '');
        if ($host === '') {
            $host = (string) ($server['SERVER_NAME'] ?? 'localhost');
            $port = (string) ($server['SERVER_PORT'] ?? '');
            if ($port !== '' && $port !== (string) (Origin::DEFAULT_PORTS[$scheme] ?? '')) {
                $host .= ":{$port}";
            }
        }
        $headers = [];
        foreach ($server as $key => $value) {
            if (is_string($key) && str_starts_with($key, 'HTTP_') && is_scalar($value)) {
                $headers[str_replace('_', '-', strtolower(substr($key, 5)))] = (string) $value;
            }
        }
        foreach (['CONTENT_TYPE' => 'content-type', 'CONTENT_LENGTH' => 'content-length'] as $key => $name) {
            if (isset($server[$key]) && $server[$key] !== '') {
                $headers[$name] = (string) $server[$key];
            }
        }
        // Apache hands the Authorization header to PHP only when told to; these are the places it may be.
        if (!isset($headers['authorization'])) {
            $authorization = $server['REDIRECT_HTTP_AUTHORIZATION'] ?? null;
            if ($authorization === null && function_exists('getallheaders') && $server === $_SERVER) {
                foreach ((array) getallheaders() as $name => $value) {
                    if (strtolower((string) $name) === 'authorization') {
                        $authorization = $value;
                    }
                }
            }
            if (is_string($authorization) && $authorization !== '') {
                $headers['authorization'] = $authorization;
            }
        }
        $script = (string) ($server['SCRIPT_NAME'] ?? '');
        $target = (string) ($server['REQUEST_URI'] ?? ($script . ($server['PATH_INFO'] ?? '') . (isset($server['QUERY_STRING']) && $server['QUERY_STRING'] !== '' ? '?' . $server['QUERY_STRING'] : '')));
        if (preg_match('#^[A-Za-z][A-Za-z0-9+.\-]*://[^/?\#]*(.*)$#Ds', $target, $m) === 1) {
            $target = $m[1];
        }
        $target = explode('#', $target, 2)[0];
        [$rawPath, $query] = array_pad(explode('?', $target, 2), 2, '');
        $path = self::normalizePath($rawPath);
        $mount = self::mountOf($path, $server);
        $type = strtolower($headers['content-type'] ?? '');
        $form = null;
        if (str_contains($type, 'multipart/form-data') && $server === $_SERVER) {
            $form = $_POST;
            foreach (array_keys($_FILES) as $name) {
                $form[$name] = new \SplFileInfo((string) $name);
            }
        }
        return new self(
            (string) ($server['REQUEST_METHOD'] ?? 'GET'),
            $path,
            $query,
            $headers,
            $input ?? static fn (): string => (string) file_get_contents('php://input'),
            self::originOf($scheme, $host),
            $mount,
            $form,
        );
    }

    /**
     * A PSR-7 ServerRequestInterface, read as the SDK reads a fetch Request.
     * Duck typed, so this package needs no PSR package to be installed.
     */
    public static function fromPsr(object $request): self
    {
        $uri = $request->getUri();
        $headers = [];
        foreach ($request->getHeaders() as $name => $values) {
            $name = strtolower((string) $name);
            $headers[$name] = implode($name === 'cookie' ? '; ' : ', ', (array) $values);
        }
        $scheme = strtolower((string) $uri->getScheme()) ?: 'http';
        $host = (string) $uri->getHost();
        $host = $host === '' ? ($headers['host'] ?? 'localhost') : $host . ($uri->getPort() !== null ? ':' . $uri->getPort() : '');
        $server = method_exists($request, 'getServerParams') ? $request->getServerParams() : [];
        $path = self::normalizePath((string) $uri->getPath());
        // PSR-7 escapes a "%" that starts no escape (%zz becomes %25zz); the
        // request target as sent, when the server passed it, keeps it as the
        // browser sent it, and is used when it is the same path.
        $raw = is_string($server['REQUEST_URI'] ?? null) ? explode('?', explode('#', $server['REQUEST_URI'], 2)[0], 2)[0] : null;
        if ($raw !== null && preg_match('#^[A-Za-z][A-Za-z0-9+.\-]*://[^/]*(.*)$#Ds', $raw, $m) === 1) {
            $raw = $m[1];
        }
        if ($raw !== null && $raw !== $path && rawurldecode(self::normalizePath($raw)) === rawurldecode($path)) {
            $path = self::normalizePath($raw);
        }
        $mount = self::mountOf($path, $server);
        $form = null;
        if (str_contains(strtolower($headers['content-type'] ?? ''), 'multipart/form-data') && method_exists($request, 'getParsedBody')) {
            $parsed = $request->getParsedBody();
            $form = is_array($parsed) ? $parsed : [];
            foreach (array_keys(method_exists($request, 'getUploadedFiles') ? $request->getUploadedFiles() : []) as $name) {
                $form[$name] = new \SplFileInfo((string) $name);
            }
        }
        $body = static function () use ($request): string {
            $stream = $request->getBody();
            if ($stream->isSeekable()) {
                $stream->rewind();
            }
            return $stream->getContents();
        };
        return new self((string) $request->getMethod(), $path, (string) $uri->getQuery(), $headers, $body, self::originOf($scheme, $host), $mount, $form);
    }

    /**
     * Where a path-info URL (/cronwatch.php/api/jobs) is mounted: its
     * script, when the path runs through a PHP file that is the script being
     * run. Null otherwise, as behind a rewrite to a front controller (or
     * under php -S with a router, which names the request path the script).
     *
     * @param array<string, mixed> $server
     */
    private static function mountOf(string $path, array $server): ?string
    {
        $script = is_string($server['SCRIPT_NAME'] ?? null) ? $server['SCRIPT_NAME'] : '';
        $file = is_string($server['SCRIPT_FILENAME'] ?? null) ? $server['SCRIPT_FILENAME'] : '';
        if (!str_ends_with($script, '.php') || ($file !== '' && basename($file) !== basename($script))) {
            return null;
        }
        return $path === $script || str_starts_with($path, $script . '/') ? $script : null;
    }

    public function header(string $name): ?string
    {
        return $this->headers[strtolower($name)] ?? null;
    }

    /** The body's bytes, read once. */
    public function body(): string
    {
        if ($this->body instanceof \Closure) {
            $this->body = (string) ($this->body)();
        }
        return $this->body;
    }

    /**
     * The query's pairs, as URLSearchParams reads them.
     *
     * @return list<array{string, string}>
     */
    public function params(): array
    {
        return self::parseQuery($this->query);
    }

    /** URLSearchParams#get: the first value, or null. */
    public function param(string $name): ?string
    {
        foreach ($this->params() as [$key, $value]) {
            if ($key === $name) {
                return $value;
            }
        }
        return null;
    }

    /** The origin of scheme://host, as URL#origin writes it (lowercased, no default port). */
    public static function originOf(string $scheme, string $host): string
    {
        return Origin::bare("{$scheme}://{$host}") ?? strtolower("{$scheme}://{$host}");
    }

    /**
     * A path as the URL parser leaves it: backslashes read as slashes,
     * characters a browser would escape percent-encoded, and "." and ".."
     * segments (written plainly or as %2e) resolved.
     */
    public static function normalizePath(string $path): string
    {
        $path = str_replace('\\', '/', $path);
        $path = (string) preg_replace_callback('/[\x00-\x20"<>`{}\x7F-\xFF]/', fn (array $m) => sprintf('%%%02X', ord($m[0])), $path);
        if ($path === '' || $path[0] !== '/') {
            $path = '/' . $path;
        }
        $segments = explode('/', substr($path, 1));
        $out = [];
        $last = count($segments) - 1;
        foreach ($segments as $i => $segment) {
            $lower = strtolower($segment);
            if (in_array($lower, ['..', '.%2e', '%2e.', '%2e%2e'], true)) {
                array_pop($out);
                if ($i === $last) {
                    $out[] = '';
                }
            } elseif ($lower === '.' || $lower === '%2e') {
                if ($i === $last) {
                    $out[] = '';
                }
            } else {
                $out[] = $segment;
            }
        }
        return '/' . implode('/', $out);
    }

    /**
     * application/x-www-form-urlencoded as URLSearchParams reads it: "+" is a
     * space, a bad escape is kept as written, bytes that are not UTF-8 become U+FFFD.
     *
     * @return list<array{string, string}>
     */
    public static function parseQuery(string $text): array
    {
        if (str_starts_with($text, '?')) {
            $text = substr($text, 1);
        }
        $pairs = [];
        foreach (explode('&', $text) as $part) {
            if ($part === '') {
                continue;
            }
            [$key, $value] = array_pad(explode('=', $part, 2), 2, '');
            $pairs[] = [Js::wellFormed(urldecode($key)), Js::wellFormed(urldecode($value))];
        }
        return $pairs;
    }

    /** The application/x-www-form-urlencoded serializer URLSearchParams writes with. */
    public static function formEncode(string $text): string
    {
        return strtr(urlencode(Js::wellFormed($text)), ['%2A' => '*', '~' => '%7E']);
    }

    /** decodeURIComponent, or null where it would throw: a bad escape, or bytes that are not UTF-8. */
    public static function safeDecode(string $value): ?string
    {
        if (preg_match('/%(?![0-9A-Fa-f]{2})/', $value) === 1) {
            return null;
        }
        $decoded = rawurldecode($value);
        return preg_match('//u', $decoded) === 1 ? $decoded : null;
    }
}
