<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\Js;

/**
 * What every email channel sends (alerts/email.ts): one subject, a plain
 * text body and a small HTML body, so an alert reads the same whichever
 * provider carries it.
 */
final class Email
{
    /**
     * @param list<string> $to
     */
    public function __construct(
        public readonly string $from,
        public readonly array $to,
        public readonly string $subject,
        public readonly string $text,
        public readonly string $html,
    ) {
    }

    /**
     * Checks the options every email channel shares, once, when the channel is made.
     *
     * @return list<string> the recipients, trimmed
     */
    public static function recipients(string $name, mixed $from, mixed $to): array
    {
        if (!Shared::present($from)) {
            throw new \InvalidArgumentException("{$name} needs a from address");
        }
        $recipients = Shared::list($to);
        if ($recipients === []) {
            throw new \InvalidArgumentException("{$name} needs at least one to address");
        }
        return $recipients;
    }

    /**
     * The email for one alert.
     *
     * @param list<string> $to
     * @param (\Closure(Alert): ?string)|null $link
     */
    public static function compose(Alert $alert, string $from, array $to, ?string $subjectPrefix = null, ?\Closure $link = null): self
    {
        $url = self::safeLink(Shared::link($link, $alert));
        // One line: a newline in a subject is a header injection or a rejected send.
        $subject = Shared::cut((string) preg_replace('/[\r\n]+/', ' ', (Shared::present($subjectPrefix) ? "{$subjectPrefix} " : '') . $alert->title), 250);
        return new self($from, $to, $subject, Shared::plainText($alert, $url), self::html($alert, $url));
    }

    /** Escapes text for HTML content and double quoted attributes. */
    public static function escapeHtml(string $text): string
    {
        return strtr($text, ['&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&#39;']);
    }

    /** Only http and https links are put in a mail; anything else is dropped. */
    private static function safeLink(?string $link): ?string
    {
        return $link !== null && $link !== '' && preg_match('/^https?:\/\//i', $link) === 1 ? $link : null;
    }

    private static function html(Alert $alert, ?string $link): string
    {
        $parts = [
            '<!doctype html>',
            '<html><body style="margin:0;padding:16px;font-family:Georgia,serif;color:#1d1b16;background:#ffffff">',
            '<p style="margin:0 0 12px;font-size:18px"><strong>' . self::escapeHtml($alert->title) . '</strong></p>',
            '<pre style="margin:0 0 12px;padding:12px;background:#f6f3ec;white-space:pre-wrap;word-break:break-word;font:13px/1.45 Menlo,Consolas,monospace">'
                . self::escapeHtml($alert->message) . '</pre>',
        ];
        if (Shared::present($alert->triage)) {
            $parts[] = '<p style="margin:0 0 12px"><em>Triage:</em> ' . self::escapeHtml((string) $alert->triage) . '</p>';
        }
        if ($link !== null) {
            $parts[] = '<p style="margin:0"><a href="' . self::escapeHtml($link) . '">Open ' . self::escapeHtml($alert->job) . '</a></p>';
        }
        $parts[] = '</body></html>';
        return implode("\n", $parts);
    }

    /**
     * Splits "Name <a@b.c>" into its parts; a bare address has no name.
     *
     * @return array{email: string, name?: string}
     */
    public static function parseAddress(string $address): array
    {
        $space = '[' . Js::WHITESPACE . ']*';
        if (preg_match("/^{$space}([^\\r\\n\\x{2028}\\x{2029}]*?){$space}<([^<>]+)>{$space}\$/Du", $address, $m) !== 1) {
            return ['email' => Js::trim($address)];
        }
        $name = (string) preg_replace('/^"([^\r\n\x{2028}\x{2029}]*)"$/Du', '$1', $m[1]);
        return $name !== '' ? ['email' => Js::trim($m[2]), 'name' => $name] : ['email' => Js::trim($m[2])];
    }
}
