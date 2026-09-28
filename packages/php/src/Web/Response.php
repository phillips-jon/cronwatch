<?php

declare(strict_types=1);

namespace Cronwatch\Web;

/**
 * What the dashboard answers: a status, headers (lowercase names, as a fetch
 * Response lists them) and the body's bytes. send() writes it with header()
 * and echo; toPsr() makes a PSR-7 response with the factories given.
 */
final class Response
{
    /** @param array<string, string> $headers */
    public function __construct(
        public readonly int $status,
        public readonly array $headers,
        public readonly string $body = '',
    ) {
    }

    public function header(string $name): ?string
    {
        return $this->headers[strtolower($name)] ?? null;
    }

    /**
     * Writes the response for the request PHP is answering: the status, the
     * headers (and a Content-Length), then the body, left out for HEAD. PHP's
     * own X-Powered-By and default Content-Type are not sent, so the headers
     * are the SDK's.
     */
    public function send(?string $method = null): void
    {
        $method ??= (string) ($_SERVER['REQUEST_METHOD'] ?? 'GET');
        if (!headers_sent()) {
            http_response_code($this->status);
            header_remove('X-Powered-By');
            if (!isset($this->headers['content-type'])) {
                // Otherwise PHP adds "Content-type: text/html" to a redirect.
                ini_set('default_mimetype', '');
            }
            foreach ($this->headers as $name => $value) {
                header(self::title($name) . ': ' . $value, true);
            }
            header('Content-Length: ' . strlen($this->body), true);
        }
        if (strtoupper($method) !== 'HEAD') {
            echo $this->body;
        }
    }

    /**
     * A PSR-7 response made with a PSR-17 response factory and stream
     * factory (duck typed, so this package needs no PSR package installed).
     */
    public function toPsr(object $responseFactory, object $streamFactory): object
    {
        $response = $responseFactory->createResponse($this->status);
        foreach ($this->headers as $name => $value) {
            $response = $response->withHeader($name, $value);
        }
        return $response->withBody($streamFactory->createStream($this->body));
    }

    /** content-type as Content-Type, the way servers write header names. */
    private static function title(string $name): string
    {
        return implode('-', array_map('ucfirst', explode('-', $name)));
    }
}
