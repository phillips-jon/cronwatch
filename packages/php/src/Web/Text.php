<?php

declare(strict_types=1);

namespace Cronwatch\Web;

use Cronwatch\Js;

/**
 * What the pages need to write values the way the SDK's templates do:
 * escapeHtml, String(value), JavaScript truthiness, encodeURIComponent,
 * Number#toFixed and Object.entries.
 *
 * @internal
 */
final class Text
{
    private const ESCAPES = ['&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;', "'" => '&#39;'];

    /** String(value), the way a template literal writes it (null as "", as `?? ""` has it). */
    public static function text(mixed $value): string
    {
        return $value === null ? '' : Js::string($value);
    }

    /** escapeHtml: String(value ?? "") with & < > " ' escaped. Every string a page shows goes through this. */
    public static function h(mixed $value): string
    {
        return strtr(self::text($value), self::ESCAPES);
    }

    /** escapeName: a job name shown as text, with a break allowed after each run of _ : . / - so it wraps at its separators. Never in an attribute. */
    public static function name(mixed $value): string
    {
        return (string) preg_replace('~([_:./-]+)(?=[^_:./-])~', '$1<wbr>', self::h($value));
    }

    /** JavaScript truthiness, for the templates' `x ? a : b`: an empty array is true there, as an empty object is. */
    public static function truthy(mixed $value): bool
    {
        if ($value === null || $value === false || $value === '') {
            return false;
        }
        if (is_int($value)) {
            return $value !== 0;
        }
        if (is_float($value)) {
            return !($value == 0.0 || is_nan($value));
        }
        return true;
    }

    /** encodeURIComponent: everything but A-Z a-z 0-9 - _ . ! ~ * ' ( ) percent-encoded as UTF-8. */
    public static function encodeUriComponent(mixed $value): string
    {
        return strtr(rawurlencode(Js::wellFormed(self::text($value))), ['%21' => '!', '%2A' => '*', '%27' => "'", '%28' => '(', '%29' => ')']);
    }

    /**
     * Number#toFixed: the nearest `digits`-place decimal to the exact value
     * of the double, a half going away from zero. PHP's own rounding
     * (round(), number_format()) rounds a decimal reading of the double
     * instead, which differs at the halves (1.005 is below a half, so
     * JavaScript writes "1.00"), so the exact digits are taken from
     * sprintf, which prints a double's exact expansion, and rounded here.
     */
    public static function toFixed(int|float $value, int $digits): string
    {
        if (!Js::isFinite($value) || abs($value) >= 1e21) {
            return Js::number($value);
        }
        $negative = $value < 0;
        // A double has at most 52 bits after the point for anything that needs rounding here.
        $exact = sprintf('%.53F', abs((float) $value));
        [$whole, $fraction] = explode('.', $exact);
        $kept = substr($fraction, 0, $digits);
        $next = $fraction[$digits] ?? '0';
        $number = ltrim($whole . $kept, '0');
        $number = $number === '' ? '0' : $number;
        if ($next >= '5') {
            $number = self::increment($number);
        }
        $number = str_pad($number, $digits + 1, '0', STR_PAD_LEFT);
        $text = $digits > 0 ? substr($number, 0, -$digits) . '.' . substr($number, -$digits) : $number;
        // (-0.04).toFixed(1) is "-0.0": the sign stays, as JavaScript keeps it for a negative value.
        return $negative ? "-{$text}" : $text;
    }

    /** One added to a string of decimal digits. */
    private static function increment(string $digits): string
    {
        $i = strlen($digits) - 1;
        while ($i >= 0 && $digits[$i] === '9') {
            $digits[$i] = '0';
            $i--;
        }
        return $i < 0 ? '1' . $digits : substr_replace($digits, (string) ((int) $digits[$i] + 1), $i, 1);
    }

    /**
     * Object.entries: array-index keys first, ascending, then the rest in
     * insertion order.
     *
     * @return list<array{string, mixed}>
     */
    public static function entries(mixed $object): array
    {
        if ($object instanceof \stdClass) {
            $object = get_object_vars($object);
        }
        if (!is_array($object)) {
            return [];
        }
        $out = [];
        foreach (Js::objectKeys($object) as $key) {
            $out[] = [$key, $object[$key]];
        }
        return $out;
    }
}
