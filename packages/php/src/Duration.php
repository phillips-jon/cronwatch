<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * Durations: "15m", "1h30m", "90s", "2d", a number of milliseconds, or a
 * DateInterval. Parsed and formatted as the SDK's duration.ts does.
 */
final class Duration
{
    public const UNIT_MS = ['ms' => 1, 's' => 1000, 'm' => 60_000, 'h' => 3_600_000, 'd' => 86_400_000, 'w' => 604_800_000];

    /**
     * The longest duration string read, in characters (code points). No real
     * duration comes near it, and the parts pattern is quadratic on a long run
     * of digits, so a longer string is refused before it is read.
     */
    public const MAX_LENGTH = 64;

    /** How much of a refused, overlong string its error quotes. */
    private const QUOTED = 32;

    /**
     * "15m" -> 900000. Accepts a plain number of milliseconds, a DateInterval,
     * and compound strings such as "1h30m". Whitespace between parts is fine.
     *
     * @throws \InvalidArgumentException for anything else, with the SDK's message
     */
    public static function parse(mixed $value, string $label = 'duration'): int|float
    {
        if ($value instanceof \DateInterval) {
            $start = new \DateTimeImmutable('@0');
            $ms = Js::round(((float) $start->add($value)->format('U.u')) * 1000);
            if ($ms < 0) {
                throw new \InvalidArgumentException("{$label} must be a non-negative number of milliseconds");
            }
            return $ms;
        }
        if (is_int($value) || is_float($value)) {
            if (!Js::isFinite($value) || $value < 0) {
                throw new \InvalidArgumentException("{$label} must be a non-negative number of milliseconds");
            }
            return $value;
        }
        if (!is_string($value)) {
            throw self::notADuration($label, Js::string($value));
        }
        if (strlen($value) > self::MAX_LENGTH) {
            self::refuseLong($value, $label);
        }
        $text = strtolower(Js::trim($value));
        if ($text === '') {
            throw new \InvalidArgumentException("{$label} is empty");
        }
        $total = 0.0;
        $consumed = '';
        preg_match_all('/([0-9]+(?:\.[0-9]+)?)[' . Js::WHITESPACE . ']*(ms|s|m|h|d|w)/u', $text, $matches, PREG_SET_ORDER);
        foreach ($matches as $match) {
            $total += (float) $match[1] * self::UNIT_MS[$match[2]];
            $consumed .= $match[0];
        }
        if (Js::stripSpaces($consumed) !== Js::stripSpaces($text)) {
            throw self::notADuration($label, $value);
        }
        return Js::round($total);
    }

    /**
     * Throws when $value is over MAX_LENGTH characters, quoting the first
     * QUOTED. A character is a UTF-8 sequence, and a byte that starts none
     * counts as one, as it would once read as U+FFFD.
     */
    private static function refuseLong(string $value, string $label): void
    {
        $n = strlen($value);
        $count = 0;
        $head = 0;
        for ($i = 0; $i < $n;) {
            $byte = ord($value[$i]);
            $width = $byte < 0xC0 ? 1 : ($byte < 0xE0 ? 2 : ($byte < 0xF0 ? 3 : 4));
            $next = $i + 1;
            while ($next < $n && $next < $i + $width && (ord($value[$next]) & 0xC0) === 0x80) {
                $next++;
            }
            $i = $next;
            if (++$count === self::QUOTED) {
                $head = $i;
            }
            if ($count > self::MAX_LENGTH) {
                $quoted = substr($value, 0, $head);
                throw new \InvalidArgumentException("{$label} \"{$quoted}...\" is too long for a duration (more than " . self::MAX_LENGTH . ' characters)');
            }
        }
    }

    private static function notADuration(string $label, string $value): \InvalidArgumentException
    {
        return new \InvalidArgumentException("{$label} \"{$value}\" is not a duration like \"15m\", \"1h30m\" or \"90s\"");
    }

    /**
     * Whole seconds as an interval schedule reads them, in the largest units
     * that fit: 86400 is "1d", 43200 "12h", 5400 "1h30m", 90 "1m30s". For
     * integrations that declare a framework's interval as "every <this>", so
     * the dashboard shows "every 1d" rather than "every 86400s".
     */
    public static function interval(int $seconds): string
    {
        $out = '';
        foreach (['d' => 86400, 'h' => 3600, 'm' => 60, 's' => 1] as $unit => $size) {
            if ($seconds >= $size) {
                $out .= intdiv($seconds, $size) . $unit;
                $seconds %= $size;
            }
        }
        return $out === '' ? '0s' : $out;
    }

    /** 90000 -> "1m 30s". For messages, not for parsing back. */
    public static function format(int|float $ms): string
    {
        if (!Js::isFinite($ms)) {
            return '?';
        }
        if ($ms < 1000) {
            return Js::number(Js::round($ms)) . 'ms';
        }
        $parts = [];
        $rest = Js::round($ms / 1000);
        foreach (['d' => 86_400, 'h' => 3_600, 'm' => 60, 's' => 1] as $unit => $size) {
            if ($rest >= $size) {
                $n = floor($rest / $size);
                $rest -= $n * $size;
                $parts[] = Js::number(Js::floor($n)) . $unit;
            }
            if (count($parts) === 2) {
                break;
            }
        }
        return $parts === [] ? '0s' : implode(' ', $parts);
    }

    /** "5m ago", "in 2h". Relative to `now`. */
    public static function relative(int|float $at, int|float $now): string
    {
        $diff = $at - $now;
        if (abs($diff) < 5_000) {
            return 'now';
        }
        $text = self::format(abs($diff));
        return $diff < 0 ? "{$text} ago" : "in {$text}";
    }
}
