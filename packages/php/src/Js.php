<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * The places JavaScript and PHP disagree about text and numbers, settled the
 * JavaScript way.
 *
 * The SDK writes the stored rows and the alert text, so this port reproduces
 * them byte for byte: Math.round, String(number), JSON.stringify (number
 * formatting, key order, escaping), String.prototype.trim, the \s class, and
 * lengths counted in UTF-16 code units. PHP strings are bytes; every string
 * here is UTF-8, made so by wellFormed() where text enters a run.
 *
 * @internal
 */
final class Js
{
    /** What JavaScript's \s and trim() treat as whitespace, for use inside a character class of a /u pattern. */
    public const WHITESPACE = '\t\n\x{0B}\f\r \x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}\x{FEFF}';

    /** Number.MAX_SAFE_INTEGER. Past it JavaScript holds an integer as the nearest double. */
    public const MAX_SAFE_INTEGER = 9007199254740991;

    private const ESCAPES = [
        '"' => '\\"', '\\' => '\\\\', "\x08" => '\\b', "\f" => '\\f', "\n" => '\\n', "\r" => '\\r', "\t" => '\\t',
    ];

    /** @var array<string, string>|null Every character JSON.stringify escapes, and how. */
    private static ?array $escapes = null;

    /** String.prototype.trim. */
    public static function trim(string $text): string
    {
        $out = preg_replace('/^[' . self::WHITESPACE . ']+|[' . self::WHITESPACE . ']+\z/u', '', $text);
        return $out ?? trim($text);
    }

    /** String.prototype.trimEnd. */
    public static function trimEnd(string $text): string
    {
        $out = preg_replace('/[' . self::WHITESPACE . ']+\z/u', '', $text);
        return $out ?? rtrim($text);
    }

    /** Text with every run of JavaScript whitespace removed, as text.replace(/\s+/g, ""). */
    public static function stripSpaces(string $text): string
    {
        return preg_replace('/[' . self::WHITESPACE . ']+/u', '', $text) ?? $text;
    }

    /** typeof value === "number", for PHP's numbers (bool is not one). */
    public static function isNumber(mixed $value): bool
    {
        return is_int($value) || is_float($value);
    }

    /** Number.isFinite. */
    public static function isFinite(mixed $value): bool
    {
        return is_int($value) || (is_float($value) && is_finite($value));
    }

    /** Number.isInteger. */
    public static function isInteger(mixed $value): bool
    {
        return is_int($value) || (is_float($value) && is_finite($value) && $value === floor($value));
    }

    /** Math.round: halves go up, toward positive infinity. An int for a finite value that fits one. */
    public static function round(int|float $value): int|float
    {
        if (is_int($value) || !is_finite($value)) {
            return $value;
        }
        $floor = floor($value);
        $rounded = $value - $floor >= 0.5 ? $floor + 1 : $floor;
        return abs($rounded) <= self::MAX_SAFE_INTEGER ? (int) $rounded : $rounded;
    }

    /** Math.floor, as an int when it fits one. */
    public static function floor(int|float $value): int|float
    {
        if (is_int($value)) {
            return $value;
        }
        $floor = floor($value);
        return is_finite($floor) && abs($floor) <= self::MAX_SAFE_INTEGER ? (int) $floor : $floor;
    }

    /**
     * The shortest digits that read back as the same double, and where the
     * decimal point goes: value = 0.DIGITS * 10 ** point. PHP's own writer
     * (serialize_precision -1) already finds the digits.
     *
     * @return array{string, int}
     */
    public static function decimal(float $value): array
    {
        $saved = ini_get('serialize_precision');
        if ($saved !== '-1') {
            ini_set('serialize_precision', '-1');
        }
        $text = var_export(abs($value), true);
        if ($saved !== '-1' && $saved !== false) {
            ini_set('serialize_precision', $saved);
        }
        $exponent = 0;
        if (preg_match('/^([0-9.]+)[eE]([+-]?[0-9]+)$/', $text, $m) === 1) {
            $text = $m[1];
            $exponent = (int) $m[2];
        }
        $dot = strpos($text, '.');
        $whole = $dot === false ? $text : substr($text, 0, $dot);
        $fraction = $dot === false ? '' : substr($text, $dot + 1);
        $digits = ltrim($whole . $fraction, '0');
        $point = strlen($whole) + $exponent - (strlen($whole . $fraction) - strlen($digits));
        $digits = rtrim($digits, '0');
        return [$digits === '' ? '0' : $digits, $digits === '' ? 1 : $point];
    }

    /** String(number): the text a template literal or JSON.stringify gives a number. */
    public static function number(int|float $value): string
    {
        if (is_int($value) && abs($value) <= self::MAX_SAFE_INTEGER) {
            return (string) $value;
        }
        $value = (float) $value;
        if (is_nan($value)) {
            return 'NaN';
        }
        if (is_infinite($value)) {
            return $value > 0 ? 'Infinity' : '-Infinity';
        }
        if ($value == 0.0) {
            return '0';
        }
        [$digits, $point] = self::decimal($value);
        $k = strlen($digits);
        if ($k <= $point && $point <= 21) {
            $text = $digits . str_repeat('0', $point - $k);
        } elseif (0 < $point && $point <= 21) {
            $text = substr($digits, 0, $point) . '.' . substr($digits, $point);
        } elseif (-6 < $point && $point <= 0) {
            $text = '0.' . str_repeat('0', -$point) . $digits;
        } else {
            $exponent = $point - 1;
            $mantissa = $k === 1 ? $digits : $digits[0] . '.' . substr($digits, 1);
            $text = $mantissa . 'e' . ($exponent < 0 ? '-' : '+') . abs($exponent);
        }
        return $value < 0 ? '-' . $text : $text;
    }

    /** String(value) as JavaScript writes a primitive, for messages. */
    public static function string(mixed $value): string
    {
        return match (true) {
            $value === null => 'null',
            $value === true => 'true',
            $value === false => 'false',
            is_int($value), is_float($value) => self::number($value),
            is_string($value) => $value,
            $value instanceof \Stringable => (string) $value,
            is_array($value) => implode(',', array_map(fn ($v) => $v === null ? '' : self::string($v), $value)),
            default => '[object Object]',
        };
    }

    /** Whether the text is ASCII only. */
    public static function isAscii(string $text): bool
    {
        return preg_match('/[\x80-\xFF]/', $text) !== 1;
    }

    /**
     * Text made valid UTF-8: every byte that does not belong to a valid
     * sequence becomes U+FFFD, as a JavaScript string decoded from those
     * bytes holds it (the WHATWG decoder: one U+FFFD per maximal subpart).
     */
    public static function wellFormed(string $text): string
    {
        if (preg_match('//u', $text) === 1) {
            return $text;
        }
        $out = '';
        $n = strlen($text);
        $i = 0;
        while ($i < $n) {
            $b = ord($text[$i]);
            if ($b < 0x80) {
                $out .= $text[$i];
                $i++;
                continue;
            }
            if ($b >= 0xC2 && $b <= 0xDF) {
                [$need, $lo, $hi] = [1, 0x80, 0xBF];
            } elseif ($b >= 0xE0 && $b <= 0xEF) {
                [$need, $lo, $hi] = [2, $b === 0xE0 ? 0xA0 : 0x80, $b === 0xED ? 0x9F : 0xBF];
            } elseif ($b >= 0xF0 && $b <= 0xF4) {
                [$need, $lo, $hi] = [3, $b === 0xF0 ? 0x90 : 0x80, $b === 0xF4 ? 0x8F : 0xBF];
            } else {
                $out .= "\u{FFFD}";
                $i++;
                continue;
            }
            $j = $i + 1;
            $ok = true;
            for ($k = 0; $k < $need; $k++) {
                if ($j >= $n) {
                    $ok = false;
                    break;
                }
                $c = ord($text[$j]);
                if ($c < $lo || $c > $hi) {
                    $ok = false;
                    break;
                }
                [$lo, $hi] = [0x80, 0xBF];
                $j++;
            }
            $out .= $ok ? substr($text, $i, $need + 1) : "\u{FFFD}";
            $i = $j;
        }
        return $out;
    }

    /** Length in UTF-16 code units, which is what String#length is in JavaScript. */
    public static function length16(string $text): int
    {
        if (self::isAscii($text)) {
            return strlen($text);
        }
        return strlen($text) - (int) preg_match_all('/[\x80-\xBF]/', $text) + (int) preg_match_all('/[\xF0-\xF7]/', $text);
    }

    /** Bytes in the UTF-8 sequence a lead byte starts. */
    private static function width(int $lead): int
    {
        return $lead < 0x80 ? 1 : ($lead < 0xE0 ? 2 : ($lead < 0xF0 ? 3 : 4));
    }

    /**
     * text.slice(0, units), counted in UTF-16 code units. A surrogate pair cut
     * in half leaves U+FFFD, the character a lone surrogate becomes once
     * written out as UTF-8 (to a store, a hash or a network).
     */
    public static function head16(string $text, int $units): string
    {
        if ($units <= 0) {
            return '';
        }
        if (self::isAscii($text)) {
            return substr($text, 0, $units);
        }
        $n = strlen($text);
        $i = 0;
        $u = 0;
        while ($i < $n && $u < $units) {
            $width = self::width(ord($text[$i]));
            $size = $width === 4 ? 2 : 1;
            if ($u + $size > $units) {
                return substr($text, 0, $i) . "\u{FFFD}";
            }
            $u += $size;
            $i += $width;
        }
        return substr($text, 0, $i);
    }

    /** text.slice(-units), counted in UTF-16 code units, the same way. */
    public static function tail16(string $text, int $units): string
    {
        if ($units <= 0) {
            return '';
        }
        if (self::isAscii($text)) {
            return strlen($text) <= $units ? $text : substr($text, -$units);
        }
        $i = strlen($text);
        $u = 0;
        while ($i > 0 && $u < $units) {
            $start = $i - 1;
            while ($start > 0 && (ord($text[$start]) & 0xC0) === 0x80) {
                $start--;
            }
            $size = self::width(ord($text[$start])) === 4 ? 2 : 1;
            if ($u + $size > $units) {
                return "\u{FFFD}" . substr($text, $i);
            }
            $u += $size;
            $i = $start;
        }
        return substr($text, $i);
    }

    /**
     * text.slice(0, units) as JavaScript takes it, in UTF-16 code units, for
     * text that goes on into JSON. A cut through a surrogate pair keeps the
     * lone high surrogate, as JavaScript does, in its three byte (WTF-8)
     * form, which quote() escapes as JSON.stringify does ("\ud83d"), so a
     * JSON body carries the SDK's bytes. Text going anywhere else is cut with
     * head16(), whose U+FFFD is what a lone surrogate becomes as UTF-8.
     */
    public static function slice16(string $text, int $units): string
    {
        $head = self::head16($text, $units);
        $cutAt = strlen($head) - 3;
        if ($cutAt < 0 || !str_ends_with($head, "\u{FFFD}") || substr($text, $cutAt, 3) === "\u{FFFD}") {
            return $head;
        }
        // The cut went through the four byte character at $cutAt: keep its high surrogate.
        $b = array_map('ord', str_split(substr($text, $cutAt, 4)));
        $code = (($b[0] & 0x07) << 18) | (($b[1] & 0x3F) << 12) | (($b[2] & 0x3F) << 6) | ($b[3] & 0x3F);
        $high = 0xD800 + (($code - 0x10000) >> 10);
        return substr($head, 0, $cutAt) . chr(0xE0 | ($high >> 12)) . chr(0x80 | (($high >> 6) & 0x3F)) . chr(0x80 | ($high & 0x3F));
    }

    /** text.slice(-units), for text that goes on into JSON: a cut pair keeps its lone low surrogate, as slice16() keeps a high one. */
    public static function sliceEnd16(string $text, int $units): string
    {
        $tail = self::tail16($text, $units);
        $kept = strlen($tail) - 3;
        if ($kept < 0 || !str_starts_with($tail, "\u{FFFD}") || substr($text, strlen($text) - strlen($tail), 3) === "\u{FFFD}") {
            return $tail;
        }
        $b = array_map('ord', str_split(substr($text, strlen($text) - $kept - 4, 4)));
        $code = (($b[0] & 0x07) << 18) | (($b[1] & 0x3F) << 12) | (($b[2] & 0x3F) << 6) | ($b[3] & 0x3F);
        $low = 0xDC00 + (($code - 0x10000) & 0x3FF);
        return chr(0xE0 | ($low >> 12)) . chr(0x80 | (($low >> 6) & 0x3F)) . chr(0x80 | ($low & 0x3F)) . substr($tail, 3);
    }

    /** A string as JSON.stringify writes it, a lone surrogate (see slice16()) escaped. */
    public static function quote(string $text): string
    {
        if (self::$escapes === null) {
            $map = self::ESCAPES;
            for ($c = 0; $c < 0x20; $c++) {
                $map[chr($c)] ??= sprintf('\\u%04x', $c);
            }
            self::$escapes = $map;
        }
        $quoted = '"' . strtr($text, self::$escapes) . '"';
        if (str_contains($quoted, "\xED") && preg_match('/\xED[\xA0-\xBF]/', $quoted) === 1) {
            $quoted = (string) preg_replace_callback(
                '/\xED[\xA0-\xBF][\x80-\xBF]/',
                fn (array $m) => sprintf('\\u%04x', 0xD000 | ((ord($m[0][1]) & 0x3F) << 6) | (ord($m[0][2]) & 0x3F)),
                $quoted,
            );
        }
        return $quoted;
    }

    /** A JSON object from a PHP array, even an empty one or one whose keys look like a list. */
    public static function obj(array|\stdClass $fields): \stdClass
    {
        return $fields instanceof \stdClass ? $fields : (object) $fields;
    }

    /**
     * Property order: array-index keys ascending, then the rest as inserted.
     *
     * @param array<array-key, mixed> $fields
     * @return list<string>
     */
    public static function objectKeys(array $fields): array
    {
        $indexes = [];
        $rest = [];
        foreach (array_keys($fields) as $key) {
            $key = (string) $key;
            if (preg_match('/^(?:0|[1-9][0-9]{0,9})$/', $key) === 1 && (int) $key < 4294967295) {
                $indexes[] = $key;
            } else {
                $rest[] = $key;
            }
        }
        if ($indexes === []) {
            return $rest;
        }
        usort($indexes, fn (string $a, string $b) => (int) $a <=> (int) $b);
        return [...$indexes, ...$rest];
    }

    /**
     * JSON.stringify for plain data: arrays (a list is a JSON array, anything
     * else an object), stdClass objects, strings, numbers, booleans and null,
     * and anything with toJson() (this package's types). A non-finite number
     * is null, as in JavaScript.
     */
    public static function stringify(mixed $value): string
    {
        if ($value === null) {
            return 'null';
        }
        if (is_bool($value)) {
            return $value ? 'true' : 'false';
        }
        if (is_string($value)) {
            return self::quote($value);
        }
        if (is_int($value)) {
            return self::number($value);
        }
        if (is_float($value)) {
            return is_finite($value) ? self::number($value) : 'null';
        }
        if (is_array($value) && array_is_list($value)) {
            return '[' . implode(',', array_map(self::stringify(...), $value)) . ']';
        }
        if (is_array($value) || $value instanceof \stdClass) {
            $fields = is_array($value) ? $value : get_object_vars($value);
            $parts = [];
            foreach (self::objectKeys($fields) as $key) {
                $parts[] = self::quote($key) . ':' . self::stringify($fields[$key]);
            }
            return '{' . implode(',', $parts) . '}';
        }
        if (is_object($value) && method_exists($value, 'toJson')) {
            return self::stringify($value->toJson());
        }
        if ($value instanceof \JsonSerializable) {
            return self::stringify($value->jsonSerialize());
        }
        throw new \InvalidArgumentException(get_debug_type($value) . ' is not JSON serializable');
    }

    /** JSON.parse, objects as stdClass so an empty object stays one. */
    public static function parse(string $text): mixed
    {
        return json_decode($text, false, 512, JSON_THROW_ON_ERROR | JSON_INVALID_UTF8_SUBSTITUTE);
    }

    /**
     * A decoded JSON object (or an array standing for one) as a PHP array of
     * its fields, keys as strings.
     *
     * @return array<string, mixed>
     */
    public static function fields(mixed $value): array
    {
        if ($value instanceof \stdClass) {
            $value = get_object_vars($value);
        }
        if (!is_array($value)) {
            return [];
        }
        $out = [];
        foreach ($value as $key => $item) {
            $out[(string) $key] = $item;
        }
        return $out;
    }

    /** A decoded JSON value with every object made a PHP array, all the way down. */
    public static function plain(mixed $value): mixed
    {
        if ($value instanceof \stdClass) {
            $value = get_object_vars($value);
        }
        if (is_array($value)) {
            return array_map(self::plain(...), $value);
        }
        return $value;
    }

    /** Date#toISOString for epoch milliseconds. */
    public static function iso(int|float $at): string
    {
        $ms = (int) floor($at);
        $seconds = self::div($ms, 1000);
        $millis = $ms - $seconds * 1000;
        $days = self::div($seconds, 86400);
        $rest = $seconds - $days * 86400;
        [$year, $month, $day] = self::civilFromDays($days);
        return sprintf('%04d-%02d-%02dT%02d:%02d:%02d.%03dZ', $year, $month, $day, intdiv($rest, 3600), intdiv($rest % 3600, 60), $rest % 60, $millis);
    }

    /** Floor division, as Python's //. */
    public static function div(int $a, int $b): int
    {
        $q = intdiv($a, $b);
        return ($a % $b !== 0 && (($a < 0) !== ($b < 0))) ? $q - 1 : $q;
    }

    /** Floor modulo, as Python's %. */
    public static function mod(int $a, int $b): int
    {
        return $a - self::div($a, $b) * $b;
    }

    /** Days since 1970-01-01 of a proleptic Gregorian date (month 1 to 12). */
    public static function daysFromCivil(int $year, int $month, int $day): int
    {
        $year -= $month <= 2 ? 1 : 0;
        $era = self::div($year, 400);
        $yoe = $year - $era * 400;
        $doy = intdiv(153 * ($month + ($month > 2 ? -3 : 9)) + 2, 5) + $day - 1;
        $doe = $yoe * 365 + intdiv($yoe, 4) - intdiv($yoe, 100) + $doy;
        return $era * 146097 + $doe - 719468;
    }

    /**
     * The year, month (1 to 12) and day of a count of days since 1970-01-01.
     *
     * @return array{int, int, int}
     */
    public static function civilFromDays(int $days): array
    {
        $days += 719468;
        $era = self::div($days, 146097);
        $doe = $days - $era * 146097;
        $yoe = intdiv($doe - intdiv($doe, 1460) + intdiv($doe, 36524) - intdiv($doe, 146096), 365);
        $y = $yoe + $era * 400;
        $doy = $doe - (365 * $yoe + intdiv($yoe, 4) - intdiv($yoe, 100));
        $mp = intdiv(5 * $doy + 2, 153);
        $d = $doy - intdiv(153 * $mp + 2, 5) + 1;
        $m = $mp + ($mp < 10 ? 3 : -9);
        return [$y + ($m <= 2 ? 1 : 0), $m, $d];
    }

    /** Date.UTC, month 0 based, every field free to overflow into the next. */
    public static function dateUtc(int $year, int $month, int $day = 1, int $hour = 0, int $minute = 0, int $second = 0, int $ms = 0): int
    {
        $year += self::div($month, 12);
        $month = self::mod($month, 12);
        $days = self::daysFromCivil($year, $month + 1, 1) + $day - 1;
        return ((($days * 24 + $hour) * 60 + $minute) * 60 + $second) * 1000 + $ms;
    }

    /** Epoch milliseconds now. */
    public static function nowMs(): int
    {
        return (int) floor(microtime(true) * 1000);
    }
}
