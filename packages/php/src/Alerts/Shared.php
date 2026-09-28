<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\AlertType;
use Cronwatch\Js;

/**
 * What the channels share (alerts/shared.ts): the POST that names the
 * provider and the URL's origin on failure with every secret cut out, the
 * stable alert id, the run summary trackers attach, and JavaScript's URL and
 * text functions where the channels lean on them.
 *
 * @internal
 */
final class Shared
{
    /** How much of a provider's error body goes into the error message. */
    public const ERROR_BODY_MAX = 200;

    private const DEFAULT_PORTS = ['http' => 80, 'https' => 443, 'ws' => 80, 'wss' => 443, 'ftp' => 21];

    /** Severity for trackers that have levels. Recovered is informational. */
    public static function severity(string $type): string
    {
        return match ($type) {
            AlertType::RECOVERED => 'info',
            AlertType::SLOW, AlertType::OVER_BUDGET => 'warning',
            default => 'error',
        };
    }

    /**
     * The parts of a URL as the WHATWG parser gives them, for the URLs the
     * channels take: protocol ("https:"), username, host (with the port
     * when it is not the scheme's default), pathname and search. Null for
     * text that is not an absolute URL with a host.
     *
     * @return array{protocol: string, scheme: string, username: string, host: string, pathname: string, search: string}|null
     */
    public static function url(string $url): ?array
    {
        $url = self::cleanUrl($url);
        if (preg_match('/^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^\/?#]*)([^?#]*)(\?[^#]*)?/', $url, $m) !== 1) {
            return null;
        }
        $scheme = strtolower($m[1]);
        $authority = $m[2];
        $at = strrpos($authority, '@');
        $userinfo = $at === false ? '' : substr($authority, 0, $at);
        $hostport = $at === false ? $authority : substr($authority, $at + 1);
        if (preg_match('/^(\[[0-9A-Fa-f:.]+\]|[^:\[\]]*)(?::([0-9]*))?$/D', $hostport, $h) !== 1 || $h[1] === '') {
            return null;
        }
        $host = strtolower($h[1]);
        if (preg_match('/[\x00-\x20#%\/<>?@\\\\^|]/', $host) === 1) {
            return null;
        }
        $port = $h[2] ?? '';
        if ($port !== '') {
            if ((int) $port > 65535) {
                return null;
            }
            $port = (string) (int) $port;
            if ((int) $port === (self::DEFAULT_PORTS[$scheme] ?? -1)) {
                $port = '';
            }
        }
        $colon = strpos($userinfo, ':');
        $path = $m[3] === '' ? '/' : $m[3];
        return [
            'protocol' => "{$scheme}:",
            'scheme' => $scheme,
            'username' => $colon === false ? $userinfo : substr($userinfo, 0, $colon),
            'host' => $host . ($port === '' ? '' : ":{$port}"),
            'pathname' => $path,
            'search' => ($m[4] ?? '') === '?' ? '' : ($m[4] ?? ''),
        ];
    }

    /**
     * A URL as the URL parser (and so fetch) reads it: characters U+0000 to
     * U+0020 around it dropped, and every tab, CR and LF inside it removed (a
     * pasted webhook URL often ends in a newline).
     */
    public static function cleanUrl(string $url): string
    {
        return str_replace(["\t", "\r", "\n"], '', trim($url, "\x00..\x20"));
    }

    /**
     * The URL, cleaned, once it is one a channel can post to: http or https
     * with a host. Refused without quoting it, since a webhook URL's path is
     * its credential: "not ftp:" for another scheme with a host, "not this
     * URL" for anything else (no scheme, no host, or a space or control
     * character left inside it).
     */
    public static function postable(string $url): string
    {
        $clean = self::cleanUrl($url);
        $parts = preg_match('/[\x00-\x20\x7F]/', $clean) === 1 ? null : self::url($clean);
        if ($parts === null) {
            throw new \InvalidArgumentException('only http and https URLs can be posted to, not this URL');
        }
        if ($parts['scheme'] !== 'http' && $parts['scheme'] !== 'https') {
            throw new \InvalidArgumentException("only http and https URLs can be posted to, not {$parts['protocol']}");
        }
        return $clean;
    }

    /**
     * An error message about a request to `url` with the URL's path, query
     * and credentials taken out, so only its origin can show: what curl,
     * PHP's streams or WordPress say can quote the URL.
     */
    public static function scrub(string $message, string $url): string
    {
        $clean = self::cleanUrl($url);
        $message = str_replace([$clean, $url], self::origin($url), $message);
        // phpcs:disable WordPress.WP.AlternativeFunctions.parse_url_parse_url -- a library that runs outside WordPress too, on PHP 8.2 or newer, where parse_url is consistent.
        $pieces = [
            (string) preg_replace('#^[A-Za-z][A-Za-z0-9+.-]*://[^/?\#]*#', '', $clean),
            (string) parse_url($clean, PHP_URL_PATH),
            (string) parse_url($clean, PHP_URL_QUERY),
            (string) parse_url($clean, PHP_URL_USER),
            (string) parse_url($clean, PHP_URL_PASS),
        ];
        // phpcs:enable WordPress.WP.AlternativeFunctions.parse_url_parse_url
        foreach ($pieces as $piece) {
            if (strlen($piece) > 1) {
                $message = str_replace($piece, '', $message);
            }
        }
        return $message;
    }

    /** new URL(url).origin: the scheme, host and port only. A URL's path or query can hold a credential. */
    public static function origin(string $url): string
    {
        $parts = self::url($url);
        if ($parts === null) {
            return '(invalid URL)';
        }
        return isset(self::DEFAULT_PORTS[$parts['scheme']]) ? "{$parts['scheme']}://{$parts['host']}" : 'null';
    }

    /**
     * POSTs and throws on a non-2xx answer. The error names the provider and
     * the URL's origin, plus the start of the response body with every
     * secret the channel holds cut out, in case a provider echoes one back
     * (see errorBody()). A redirect is not followed: its 3xx is an error
     * like any other answer outside 2xx.
     *
     * @param array<string, string> $headers
     * @param list<string|null> $secrets
     */
    public static function post(Http $http, string $provider, string $url, array $headers, string $body, array $secrets = []): HttpResponse
    {
        $response = $http->post(self::postable($url), $body, $headers);
        if ($response->ok()) {
            return $response;
        }
        $text = $response->body;
        throw new \RuntimeException("{$provider} " . self::origin($url) . " answered {$response->status}" . ($text !== '' ? ': ' . self::errorBody($text, $secrets) : ''));
    }

    /**
     * The start of an error body: secrets are cut out of a prefix long enough
     * to hold one that starts inside the first ERROR_BODY_MAX characters, and
     * only then is it cut to that length, on a code point, so no part of a
     * secret survives at the edge.
     *
     * @param list<string|null> $secrets
     */
    public static function errorBody(string $text, array $secrets = []): string
    {
        $kept = array_values(array_filter($secrets, fn ($s) => is_string($s) && Js::length16($s) >= 4));
        $longest = array_reduce($kept, fn (int $n, string $s) => max($n, Js::length16($s)), 0);
        $head = self::cut($text, self::ERROR_BODY_MAX + $longest);
        foreach ($kept as $secret) {
            $head = str_replace($secret, '[redacted]', $head);
        }
        return self::cut($head, self::ERROR_BODY_MAX);
    }

    /** A credential with the spaces and newlines a paste leaves around it taken off. Anything not a string is "". */
    public static function trimmed(mixed $value): string
    {
        return is_string($value) ? Js::trim($value) : '';
    }

    /** A required credential, trimmed: throws when it is missing, not a string, or only whitespace. */
    public static function required(mixed $value, string $message): string
    {
        $credential = self::trimmed($value);
        if ($credential === '') {
            throw new \InvalidArgumentException($message);
        }
        return $credential;
    }

    /** JavaScript's truthiness for an optional string: null, false and "" are absent. */
    public static function present(mixed $value): bool
    {
        return $value !== null && $value !== '' && $value !== false;
    }

    /** The link option's answer for this alert, or null. */
    public static function link(?\Closure $link, Alert $alert): ?string
    {
        if ($link === null) {
            return null;
        }
        $value = $link($alert);
        return self::present($value) ? Js::string($value) : null;
    }

    public static function basicAuth(string $user, string $password): string
    {
        return 'Basic ' . base64_encode(Js::wellFormed("{$user}:{$password}"));
    }

    public static function sha256Hex(string $text): string
    {
        return hash('sha256', Js::wellFormed($text));
    }

    /**
     * A stable 32 hex character id for one alert: the same job, type and time
     * always give the same id, so a provider that deduplicates on it drops a
     * resend of an alert it already took.
     */
    public static function alertId(Alert $alert): string
    {
        return substr(self::sha256Hex("{$alert->job}\n{$alert->type}\n" . Js::number($alert->at)), 0, 32);
    }

    /** The same id laid out as a UUID, for APIs that ask for one. */
    public static function asUuid(string $id): string
    {
        return substr($id, 0, 8) . '-' . substr($id, 8, 4) . '-' . substr($id, 12, 4) . '-' . substr($id, 16, 4) . '-' . substr($id, 20, 12);
    }

    /** At most `max` UTF-16 units, without splitting a surrogate pair (shared.ts's cut). */
    public static function cut(string $text, int $max): string
    {
        if (Js::length16($text) <= $max) {
            return $text;
        }
        $head = Js::head16($text, $max);
        // head16 leaves U+FFFD where it cut through a pair; cut() leaves the whole pair out.
        $at = strlen($head) - 3;
        return $at >= 0 && substr($head, $at) === "\u{FFFD}" && substr($text, $at, 3) !== "\u{FFFD}" ? substr($head, 0, $at) : $head;
    }

    /** The run fields worth attaching to a tracker event. */
    public static function runSummary(Alert $alert): ?array
    {
        $run = $alert->run;
        if ($run === null) {
            return null;
        }
        return ['id' => $run->id, 'status' => $run->status, 'startedAt' => Js::iso($run->startedAt), 'durationMs' => $run->durationMs, 'trigger' => $run->trigger];
    }

    /** Title, message, triage and link as one plain text block, the way every channel reads. */
    public static function plainText(Alert $alert, ?string $link): string
    {
        $lines = [$alert->title, '', $alert->message];
        if (self::present($alert->triage)) {
            array_push($lines, '', "Triage: {$alert->triage}");
        }
        if (self::present($link)) {
            array_push($lines, '', "Open: {$link}");
        }
        return implode("\n", $lines);
    }

    /** encodeURIComponent. */
    public static function encodeUriComponent(string $text): string
    {
        return strtr(rawurlencode(Js::wellFormed($text)), ['%21' => '!', '%2A' => '*', '%27' => "'", '%28' => '(', '%29' => ')']);
    }

    /**
     * URLSearchParams#toString for these pairs: application/x-www-form-urlencoded.
     *
     * @param list<array{string, string}> $pairs
     */
    public static function form(array $pairs): string
    {
        $encode = fn (string $text) => str_replace('%2A', '*', urlencode(Js::wellFormed($text)));
        return implode('&', array_map(fn (array $p) => $encode($p[0]) . '=' . $encode($p[1]), $pairs));
    }

    /**
     * Recipients as the SDK takes them: one string or several, blanks dropped, each trimmed.
     *
     * @return list<string>
     */
    public static function list(mixed $value): array
    {
        $items = is_array($value) ? array_values($value) : [$value];
        return array_values(array_map(Js::trim(...), array_filter($items, fn ($a) => is_string($a) && Js::trim($a) !== '')));
    }
}
