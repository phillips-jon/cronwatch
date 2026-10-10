<?php

declare(strict_types=1);

namespace Cronwatch\Web;

use Cronwatch\Js;

/**
 * Origins read as the SDK's `new URL(value).origin` reads them: spaces and
 * control characters around the value and tabs or line breaks in it are
 * dropped, slashes after the scheme may be missing or backslashes,
 * credentials are ignored, the host is lowercased (percent escapes decoded,
 * IPv4 numbers written out, IPv6 compressed, a non-ASCII host converted to
 * punycode) and a default port is left out.
 *
 * @internal
 */
final class Origin
{
    public const DEFAULT_PORTS = ['http' => 80, 'https' => 443];

    /**
     * The `origin` option as scheme://host[:port], or null for null or "".
     * Throws InvalidArgumentException with the SDK's message otherwise, so a
     * typo fails when the routes are made.
     */
    public static function parse(?string $value): ?string
    {
        if ($value === null || $value === '') {
            return null;
        }
        $read = self::read($value);
        if ($read === 'not-http') {
            throw new \InvalidArgumentException('routes: origin must be http or https, got ' . Js::quote($value));
        }
        if ($read === null) {
            throw new \InvalidArgumentException('routes: origin must be an absolute URL such as "https://app.example.com", got ' . Js::quote($value));
        }
        return $read[0];
    }

    /**
     * scheme://host[:port] for text that is a scheme and a bare host (what
     * trustProxy builds from the forwarded headers), or null when it carries a
     * path, credentials, a query, or a fragment, or is not an http or https URL.
     */
    public static function bare(string $value): ?string
    {
        $read = self::read($value);
        return is_array($read) && !$read[1] ? $read[0] : null;
    }

    /**
     * [origin, whether anything past the host would show in the URL: a path
     * other than "/", credentials, a query, or a fragment], "not-http" for
     * another scheme, or null for text that is not a URL.
     *
     * @return array{string, bool}|string|null
     */
    private static function read(string $value): array|string|null
    {
        $text = str_replace(["\t", "\n", "\r"], '', (string) preg_replace('/^[\x00-\x20]+|[\x00-\x20]+$/D', '', $value));
        if (preg_match('/^([A-Za-z][A-Za-z0-9+.\-]*):(.*)$/Ds', $text, $m) !== 1) {
            return null;
        }
        $scheme = strtolower($m[1]);
        if (!isset(self::DEFAULT_PORTS[$scheme])) {
            return 'not-http';
        }
        $rest = ltrim($m[2], '/\\');
        $end = strcspn($rest, '/\\?#');
        $authority = substr($rest, 0, $end);
        $after = substr($rest, $end);
        $at = strrpos($authority, '@');
        $userinfo = $at === false ? '' : substr($authority, 0, $at);
        $hostport = $at === false ? $authority : substr($authority, $at + 1);
        $split = self::splitPort($hostport);
        if ($split === null) {
            return null;
        }
        [$host, $port] = $split;
        $host = self::readHost($host);
        if ($host === null) {
            return null;
        }
        $shown = $port === null || $port === self::DEFAULT_PORTS[$scheme] ? '' : ":{$port}";
        $extra = ($at !== false && $userinfo !== '' && $userinfo !== ':') || self::pastHost($after);
        return ["{$scheme}://{$host}{$shown}", $extra];
    }

    private static function pastHost(string $after): bool
    {
        $hash = strpos($after, '#');
        $fragment = $hash === false ? '' : substr($after, $hash + 1);
        $path = $hash === false ? $after : substr($after, 0, $hash);
        $question = strpos($path, '?');
        $query = $question === false ? '' : substr($path, $question + 1);
        $path = $question === false ? $path : substr($path, 0, $question);
        return !in_array($path, ['', '/', '\\'], true) || $query !== '' || $fragment !== '';
    }

    /** @return array{string, int|null}|null */
    private static function splitPort(string $authority): ?array
    {
        if (str_starts_with($authority, '[')) {
            $close = strpos($authority, ']');
            if ($close === false) {
                return null;
            }
            $host = substr($authority, 0, $close + 1);
            $rest = substr($authority, $close + 1);
        } else {
            $colon = strrpos($authority, ':');
            $host = $colon === false ? $authority : substr($authority, 0, $colon);
            $rest = $colon === false ? '' : substr($authority, $colon);
        }
        if ($rest === '' || $rest === ':') {
            return [$host, null];
        }
        if ($rest[0] !== ':' || preg_match('/^[0-9]+$/D', substr($rest, 1)) !== 1) {
            return null;
        }
        $digits = ltrim(substr($rest, 1), '0');
        if (strlen($digits) > 5 || (int) $digits > 65_535) {
            return null;
        }
        return [$host, (int) $digits];
    }

    private static function readHost(string $host): ?string
    {
        if ($host === '') {
            return null;
        }
        if (str_starts_with($host, '[')) {
            if (!str_ends_with($host, ']') || str_contains($host, '%')) {
                return null;
            }
            $packed = @inet_pton(substr($host, 1, -1));
            return $packed === false || strlen($packed) !== 16 ? null : '[' . self::ipv6($packed) . ']';
        }
        // Escapes decoded (a "%" that is not one stays, and is refused below); bytes that are not UTF-8 are refused.
        $decoded = rawurldecode($host);
        if (preg_match('//u', $decoded) !== 1) {
            return null;
        }
        if (!Js::isAscii($decoded)) {
            $decoded = self::toAscii($decoded);
            if ($decoded === null) {
                return null;
            }
        }
        $decoded = strtolower($decoded);
        if ($decoded === '' || preg_match('/[\x00-\x20#%\/:<>?@\[\\\\\]^|\x7f]/', $decoded) === 1) {
            return null;
        }
        $address = self::ipv4($decoded);
        return $address === false ? null : ($address ?? $decoded);
    }

    /** A host outside ASCII as IDNA writes it (punycode), through intl when it is loaded. */
    private static function toAscii(string $host): ?string
    {
        if (function_exists('idn_to_ascii')) {
            $ascii = idn_to_ascii($host, IDNA_NONTRANSITIONAL_TO_ASCII | IDNA_CHECK_BIDI | IDNA_CHECK_CONTEXTJ, INTL_IDNA_VARIANT_UTS46);
            return is_string($ascii) && $ascii !== '' ? $ascii : null;
        }
        $labels = [];
        foreach (explode('.', $host) as $label) {
            $label = strtolower($label);
            $labels[] = Js::isAscii($label) ? $label : 'xn--' . self::punycode($label);
        }
        return implode('.', $labels);
    }

    /** RFC 3492's encoding of one label, for a PHP without intl (no case mapping beyond ASCII). */
    private static function punycode(string $label): string
    {
        $codes = [];
        foreach (preg_split('//u', $label, -1, PREG_SPLIT_NO_EMPTY) ?: [] as $char) {
            $codes[] = self::codePoint($char);
        }
        $output = '';
        foreach ($codes as $code) {
            if ($code < 0x80) {
                $output .= chr($code);
            }
        }
        $basic = strlen($output);
        $handled = $basic;
        if ($basic > 0) {
            $output .= '-';
        }
        [$n, $delta, $bias] = [0x80, 0, 72];
        $digit = fn (int $d): string => chr($d < 26 ? $d + 97 : $d + 22);
        while ($handled < count($codes)) {
            $m = min(array_filter($codes, fn (int $c) => $c >= $n));
            $delta += ($m - $n) * ($handled + 1);
            $n = $m;
            foreach ($codes as $code) {
                if ($code < $n) {
                    $delta++;
                }
                if ($code === $n) {
                    $q = $delta;
                    for ($k = 36;; $k += 36) {
                        $t = $k <= $bias ? 1 : ($k >= $bias + 26 ? 26 : $k - $bias);
                        if ($q < $t) {
                            break;
                        }
                        $output .= $digit($t + ($q - $t) % (36 - $t));
                        $q = intdiv($q - $t, 36 - $t);
                    }
                    $output .= $digit($q);
                    $delta = $handled === $basic ? intdiv($delta, 700) : intdiv($delta, 2);
                    $delta += intdiv($delta, $handled + 1);
                    $k = 0;
                    while ($delta > 455) {
                        $delta = intdiv($delta, 35);
                        $k += 36;
                    }
                    $bias = $k + intdiv(36 * $delta, $delta + 38);
                    $delta = 0;
                    $handled++;
                }
            }
            $delta++;
            $n++;
        }
        return $output;
    }

    /** The code point of one UTF-8 character, without mbstring. */
    private static function codePoint(string $char): int
    {
        $bytes = array_map('ord', str_split($char));
        return match (count($bytes)) {
            1 => $bytes[0],
            2 => (($bytes[0] & 0x1F) << 6) | ($bytes[1] & 0x3F),
            3 => (($bytes[0] & 0x0F) << 12) | (($bytes[1] & 0x3F) << 6) | ($bytes[2] & 0x3F),
            default => (($bytes[0] & 0x07) << 18) | (($bytes[1] & 0x3F) << 12) | (($bytes[2] & 0x3F) << 6) | ($bytes[3] & 0x3F),
        };
    }

    /** An IPv6 address as the URL parser writes it: lowercase hex, the longest run of two or more zero pieces as "::". */
    private static function ipv6(string $packed): string
    {
        $pieces = array_values(unpack('n8', $packed) ?: []);
        [$best, $bestLength, $start, $length] = [-1, 0, -1, 0];
        foreach ($pieces as $i => $piece) {
            if ($piece === 0) {
                if ($start < 0) {
                    [$start, $length] = [$i, 0];
                }
                $length++;
                if ($length > $bestLength) {
                    [$best, $bestLength] = [$start, $length];
                }
            } else {
                $start = -1;
            }
        }
        if ($bestLength < 2) {
            $best = -1;
        }
        $out = '';
        for ($i = 0; $i < 8; $i++) {
            if ($i === $best) {
                $out .= $i === 0 ? '::' : ':';
                $i += $bestLength - 1;
                continue;
            }
            $out .= dechex($pieces[$i]) . ($i < 7 ? ':' : '');
        }
        return $out;
    }

    /**
     * WHATWG's IPv4 parser, for a host whose last label is a number: "127.1"
     * and "0x7f.1" are 127.0.0.1. Null for a host that is a name, false for
     * one that looks like a number and is not an address (the URL parser
     * refuses it).
     */
    private static function ipv4(string $host): string|false|null
    {
        $parts = explode('.', $host);
        if (count($parts) > 1 && end($parts) === '') {
            array_pop($parts);
        }
        $last = end($parts);
        if (preg_match('/^(?:[0-9]+|0[xX][0-9A-Fa-f]*)$/D', (string) $last) !== 1) {
            return null;
        }
        $bad = false;
        if (count($parts) > 4) {
            return $bad;
        }
        $numbers = [];
        foreach ($parts as $part) {
            $number = self::number($part);
            if ($number === null) {
                return $bad;
            }
            $numbers[] = $number;
        }
        $lastNumber = array_pop($numbers);
        foreach ($numbers as $n) {
            if ($n > 255) {
                return $bad;
            }
        }
        if ($lastNumber >= 256 ** (4 - count($numbers))) {
            return $bad;
        }
        $address = $lastNumber;
        foreach ($numbers as $i => $n) {
            $address += $n * 256 ** (3 - $i);
        }
        return implode('.', [($address >> 24) & 255, ($address >> 16) & 255, ($address >> 8) & 255, $address & 255]);
    }

    private static function number(string $part): int|float|null
    {
        if ($part === '') {
            return null;
        }
        if (preg_match('/^0[xX]([0-9A-Fa-f]*)$/D', $part, $m) === 1) {
            return $m[1] === '' ? 0 : (strlen(ltrim($m[1], '0')) > 12 ? INF : hexdec($m[1]));
        }
        if (preg_match('/^0[0-7]+$/D', $part) === 1) {
            return strlen($part) > 20 ? INF : octdec($part);
        }
        if (preg_match('/^[0-9]+$/D', $part) === 1 && ($part === '0' || $part[0] !== '0')) {
            return strlen($part) > 15 ? INF : (int) $part;
        }
        return null;
    }
}
