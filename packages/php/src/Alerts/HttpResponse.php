<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Js;

/** An HTTP answer: its status and its body, read as fetch's response.text() reads it. */
final class HttpResponse
{
    public readonly string $body;

    public function __construct(public readonly int $status, string $body = '')
    {
        $this->body = self::text($body);
    }

    public function ok(): bool
    {
        return $this->status >= 200 && $this->status < 300;
    }

    /** Bytes as response.text() reads them: UTF-8, U+FFFD for bytes that are not, no byte order mark. */
    public static function text(string $bytes): string
    {
        $text = Js::wellFormed($bytes);
        return str_starts_with($text, "\u{FEFF}") ? substr($text, 3) : $text;
    }
}
