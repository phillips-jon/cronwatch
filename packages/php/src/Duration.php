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

    private static function notADuration(string $label, string $value): \InvalidArgumentException
    {
        return new \InvalidArgumentException("{$label} \"{$value}\" is not a duration like \"15m\", \"1h30m\" or \"90s\"");
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
