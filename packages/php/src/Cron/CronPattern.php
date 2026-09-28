<?php

declare(strict_types=1);

namespace Cronwatch\Cron;

use Cronwatch\Js;

/**
 * A port of croner 10's CronPattern (the cron library the SDK uses): the
 * fields of an expression as tables of what matches, with croner's checks
 * and messages. The names and the order of every step follow croner's
 * source, as the Python port's _cron.py does, so the two agree on every
 * expression they read and every one they refuse.
 *
 * @internal
 */
final class CronPattern
{
    /** Croner's bits for "the nth weekday of the month"; 32 is the last one, 63 any. */
    public const NTH = [1, 2, 4, 8, 16];
    public const LAST = 32;
    public const ANY = 63;

    private const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
    private const DAYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

    /** @var list<int|string> */
    public array $second;
    /** @var list<int|string> */
    public array $minute;
    /** @var list<int|string> */
    public array $hour;
    /** @var list<int|string> */
    public array $day;
    /** @var list<int|string> */
    public array $month;
    /** @var list<int> */
    public array $dayOfWeek;
    /**
     * @var array<int, int|string> The years that match, sparse: croner's
     * table of 10,000 would be kept for every schedule parsed. See hasYear().
     */
    public array $year = [];
    /** Every year matches ("*"). */
    public bool $everyYear = false;
    /** @var list<int|string> */
    public array $nearestWeekdays;
    public bool $lastDayOfMonth = false;
    public bool $lastWeekday = false;
    public bool $starDOM = false;
    public bool $starDOW = false;
    public bool $starYear = false;
    public bool $useAndLogic = false;

    public function __construct(public string $pattern)
    {
        $this->second = array_fill(0, 60, 0);
        $this->minute = array_fill(0, 60, 0);
        $this->hour = array_fill(0, 24, 0);
        $this->day = array_fill(0, 31, 0);
        $this->month = array_fill(0, 12, 0);
        $this->dayOfWeek = array_fill(0, 7, 0);
        $this->nearestWeekdays = array_fill(0, 31, 0);
        $this->parse();
    }

    /** How many entries each field's table has, as croner sizes them. */
    private const SIZES = ['second' => 60, 'minute' => 60, 'hour' => 24, 'day' => 31, 'month' => 12, 'dayOfWeek' => 7, 'year' => 10_000, 'nearestWeekdays' => 31];

    /** Whether year `y` is in the year table (croner's `year[y]`, 0 outside it). */
    public function hasYear(int $y): bool
    {
        return $y >= 0 && $y < 10_000 && ($this->everyYear || !empty($this->year[$y]));
    }

    /** parseInt(text, 10): null for NaN. */
    private static function parseInt(string $text): ?int
    {
        return preg_match('/^[' . Js::WHITESPACE . ']*([+-]?[0-9]+)/u', $text, $m) === 1 ? (int) $m[1] : null;
    }

    /** JavaScript's Number(text), for the characters a field may hold. NaN when it is not a number. */
    private static function toNumber(string $text): float
    {
        $stripped = Js::trim($text);
        if ($stripped === '') {
            return 0.0;
        }
        if (preg_match('/^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/D', $stripped) === 1) {
            return (float) $stripped;
        }
        return NAN;
    }

    private function parse(): void
    {
        if (str_contains($this->pattern, '@')) {
            $this->pattern = Js::trim(self::nicknames($this->pattern));
        }
        preg_match_all('/[^' . Js::WHITESPACE . ']+/u', $this->pattern, $found);
        $parts = $found[0] === [] ? [''] : $found[0];
        if (count($parts) < 5 || count($parts) > 7) {
            throw new CronError("CronPattern: invalid configuration format ('{$this->pattern}'), exactly five, six, or seven space separated parts are required.");
        }
        if (count($parts) === 5) {
            array_unshift($parts, '0');
        }
        if (count($parts) === 6) {
            $parts[] = '*';
        }
        if (strtoupper($parts[3]) === 'LW') {
            $this->lastWeekday = true;
            $parts[3] = '';
        } elseif (str_contains(strtoupper($parts[3]), 'L')) {
            $parts[3] = str_ireplace('L', '', $parts[3]);
            $this->lastDayOfMonth = true;
        }
        if ($parts[3] === '*') {
            $this->starDOM = true;
        }
        if ($parts[6] === '*') {
            $this->starYear = true;
        }
        if (Js::length16($parts[4]) >= 3) {
            $parts[4] = self::alphaMonths($parts[4]);
        }
        if (Js::length16($parts[5]) >= 3) {
            $parts[5] = self::alphaDays($parts[5]);
        }
        if (str_starts_with($parts[5], '+')) {
            $this->useAndLogic = true;
            $parts[5] = substr($parts[5], 1);
            if ($parts[5] === '') {
                throw new CronError("CronPattern: Day-of-week field cannot be empty after '+' modifier.");
            }
        }
        if ($parts[5] === '*') {
            $this->starDOW = true;
        }
        if (str_contains($this->pattern, '?')) {
            $parts = array_map(fn (string $p) => str_replace('?', '*', $p), $parts);
        }
        self::illegalCharacters($parts);
        $this->part('second', $parts[0], 0, 1);
        $this->part('minute', $parts[1], 0, 1);
        $this->part('hour', $parts[2], 0, 1);
        $this->part('day', $parts[3], -1, 1);
        $this->part('month', $parts[4], -1, 1);
        $this->part('dayOfWeek', $parts[5], 0, self::ANY);
        $this->part('year', $parts[6], 0, 1);
    }

    private static function nicknames(string $pattern): string
    {
        $text = strtolower(Js::trim($pattern));
        return match ($text) {
            '@yearly', '@annually' => '0 0 1 1 *',
            '@monthly' => '0 0 1 * *',
            '@weekly' => '0 0 * * 0',
            '@daily', '@midnight' => '0 0 * * *',
            '@hourly' => '0 * * * *',
            '@reboot' => throw new CronError('CronPattern: @reboot is not supported in this environment. This is an event-based trigger that requires system startup detection.'),
            default => $pattern,
        };
    }

    private static function alphaMonths(string $text): string
    {
        foreach (self::MONTHS as $i => $name) {
            $text = str_ireplace($name, (string) ($i + 1), $text);
        }
        return $text;
    }

    private static function alphaDays(string $text): string
    {
        $text = str_ireplace('-sun', '-7', $text);
        foreach (self::DAYS as $i => $name) {
            $text = str_ireplace($name, (string) $i, $text);
        }
        return $text;
    }

    /** @param list<string> $parts */
    private static function illegalCharacters(array $parts): void
    {
        foreach ($parts as $i => $part) {
            $illegal = $i === 3 ? '/[^\/*0-9,\-WwLl]+/' : ($i === 5 ? '/[^\/*0-9,\-#Ll]+/' : '/[^\/*0-9,\-]+/');
            if (preg_match($illegal, $part) === 1) {
                throw new CronError("CronPattern: configuration entry {$i} ({$part}) contains illegal characters.");
            }
        }
    }

    private function part(string $kind, string $text, int $offset, int|string $value): void
    {
        $lastDom = $kind === 'day' && $this->lastDayOfMonth;
        $lastWd = $kind === 'day' && $this->lastWeekday;
        if ($text === '' && !$lastDom && !$lastWd) {
            throw new CronError("CronPattern: configuration entry {$kind} ({$text}) is empty, check for trailing spaces.");
        }
        if ($text === '*') {
            if ($kind === 'year') {
                $this->everyYear = true;
                return;
            }
            $this->{$kind} = array_fill(0, self::SIZES[$kind], $value);
            return;
        }
        $items = explode(',', $text);
        if (count($items) > 1) {
            foreach ($items as $item) {
                $this->part($kind, $item, $offset, $value);
            }
        } elseif (str_contains($text, '-') && str_contains($text, '/')) {
            $this->rangeWithStepping($text, $kind, $offset, $value);
        } elseif (str_contains($text, '-')) {
            $this->range($text, $kind, $offset, $value);
        } elseif (str_contains($text, '/')) {
            $this->stepping($text, $kind, $value);
        } elseif ($text !== '') {
            $this->number($text, $kind, $offset, $value);
        }
    }

    /** Python's `nth[1] or value`: the modifier when there is one, else the field's value. */
    private static function modifierOr(?string $nth, int|string $value): int|string
    {
        return $nth !== null && $nth !== '' ? $nth : $value;
    }

    private function number(string $text, string $kind, int $offset, int|string $value): void
    {
        $nth = $this->extractNth($text, $kind);
        $nearest = str_contains(strtoupper($text), 'W');
        if ($kind !== 'day' && $nearest) {
            throw new CronError('CronPattern: Nearest weekday modifier (W) only allowed in day-of-month.');
        }
        if ($nearest) {
            $kind = 'nearestWeekdays';
        }
        $n = self::parseInt($nth[0]);
        if ($n === null) {
            throw new CronError("CronPattern: {$kind} is not a number: '{$text}'");
        }
        $this->set($kind, $n + $offset, self::modifierOr($nth[1], $value));
    }

    private function set(string $kind, int $at, int|string $value): void
    {
        if ($kind === 'dayOfWeek') {
            if ($at === 7) {
                $at = 0;
            }
            if ($at < 0 || $at > 6) {
                throw new CronError("CronPattern: Invalid value for dayOfWeek: {$at}");
            }
            $this->nthWeekday($at, $value);
            return;
        }
        $ok = match ($kind) {
            'second', 'minute' => $at >= 0 && $at < 60,
            'hour' => $at >= 0 && $at < 24,
            'day', 'nearestWeekdays' => $at >= 0 && $at < 31,
            'month' => $at >= 0 && $at < 12,
            'year' => $at >= 1 && $at < 10_000
                ? true
                : throw new CronError("CronPattern: Invalid value for {$kind}: {$at} (supported range: 1-9999)"),
            default => true,
        };
        if (!$ok) {
            throw new CronError("CronPattern: Invalid value for {$kind}: {$at}");
        }
        $this->{$kind}[$at] = $value;
    }

    private static function validateRange(int $low, int $high, ?int $step, int $size, string $text): void
    {
        if ($low > $high) {
            throw new CronError("CronPattern: From value is larger than to value: '{$text}'");
        }
        if ($step !== null) {
            if ($step === 0) {
                throw new CronError('CronPattern: Syntax error, illegal stepping: 0');
            }
            if ($step > $size) {
                throw new CronError("CronPattern: Syntax error, steps cannot be greater than maximum value of part ({$size})");
            }
        }
    }

    private function rangeWithStepping(string $text, string $kind, int $offset, int|string $value): void
    {
        if (str_contains(strtoupper($text), 'W')) {
            throw new CronError('CronPattern: Syntax error, W is not allowed in ranges with stepping.');
        }
        $nth = $this->extractNth($text, $kind);
        if (preg_match('/^([0-9]+)-([0-9]+)\/([0-9]+)$/D', $nth[0], $m) !== 1) {
            throw new CronError("CronPattern: Syntax error, illegal range with stepping: '{$text}'");
        }
        $low = (int) $m[1] + $offset;
        $high = (int) $m[2] + $offset;
        $step = (int) $m[3];
        self::validateRange($low, $high, $step, self::SIZES[$kind], $text);
        for ($at = $low; $at <= $high; $at += $step) {
            $this->set($kind, $at, self::modifierOr($nth[1], $value));
        }
    }

    /** @return array{string, ?string} */
    private function extractNth(string $text, string $kind): array
    {
        if (str_contains($text, '#')) {
            if ($kind !== 'dayOfWeek') {
                throw new CronError('CronPattern: nth (#) only allowed in day-of-week field');
            }
            $pieces = explode('#', $text);
            return [$pieces[0], $pieces[1]];
        }
        if (str_ends_with(strtoupper($text), 'L')) {
            if ($kind !== 'dayOfWeek') {
                throw new CronError('CronPattern: L modifier only allowed in day-of-week field (use L alone for day-of-month)');
            }
            return [substr($text, 0, -1), 'L'];
        }
        return [$text, null];
    }

    private function range(string $text, string $kind, int $offset, int|string $value): void
    {
        if (str_contains(strtoupper($text), 'W')) {
            throw new CronError('CronPattern: Syntax error, W is not allowed in a range.');
        }
        $nth = $this->extractNth($text, $kind);
        $bounds = explode('-', $nth[0]);
        if (count($bounds) !== 2) {
            throw new CronError("CronPattern: Syntax error, illegal range: '{$text}'");
        }
        $low = self::parseInt($bounds[0]);
        $high = self::parseInt($bounds[1]);
        if ($low === null) {
            throw new CronError('CronPattern: Syntax error, illegal lower range (NaN)');
        }
        if ($high === null) {
            throw new CronError('CronPattern: Syntax error, illegal upper range (NaN)');
        }
        $low += $offset;
        $high += $offset;
        self::validateRange($low, $high, null, self::SIZES[$kind], $text);
        for ($at = $low; $at <= $high; $at++) {
            $this->set($kind, $at, self::modifierOr($nth[1], $value));
        }
    }

    private function stepping(string $text, string $kind, int|string $value): void
    {
        if (str_contains(strtoupper($text), 'W')) {
            throw new CronError('CronPattern: Syntax error, W is not allowed in parts with stepping.');
        }
        $nth = $this->extractNth($text, $kind);
        $parts = explode('/', $nth[0]);
        if (count($parts) !== 2) {
            throw new CronError("CronPattern: Syntax error, illegal stepping: '{$text}'");
        }
        if ($parts[0] === '') {
            throw new CronError("CronPattern: Syntax error, stepping with missing prefix ('{$text}') is not allowed. Use wildcard (*/step) or range (min-max/step) instead.");
        }
        if ($parts[0] !== '*') {
            throw new CronError("CronPattern: Syntax error, stepping with numeric prefix ('{$text}') is not allowed. Use wildcard (*/step) or range (min-max/step) instead.");
        }
        $step = self::parseInt($parts[1]);
        if ($step === null) {
            throw new CronError('CronPattern: Syntax error, illegal stepping: (NaN)');
        }
        $size = self::SIZES[$kind];
        self::validateRange(0, $size - 1, $step, $size, $text);
        if ($step > 0) {
            for ($at = 0; $at < $size; $at += $step) {
                $this->set($kind, $at, self::modifierOr($nth[1], $value));
            }
        }
    }

    private function nthWeekday(int $day, int|string $nth): void
    {
        if (is_string($nth) && strtoupper($nth) === 'L') {
            $this->dayOfWeek[$day] |= self::LAST;
            return;
        }
        if ($nth === self::ANY) {
            $this->dayOfWeek[$day] = self::ANY;
            return;
        }
        $n = is_string($nth) ? self::toNumber($nth) : (float) $nth;
        if ($n < 6 && $n > 0) {
            $index = $n - 1;
            if ($index === floor($index) && $index >= 0 && $index < count(self::NTH)) {
                $this->dayOfWeek[$day] |= self::NTH[(int) $index];
            }
            return;
        }
        $type = is_string($nth) ? 'string' : 'number';
        $shown = is_string($nth) ? $nth : Js::number($nth);
        throw new CronError("CronPattern: nth weekday out of range, should be 1-5 or L. Value: {$shown}, Type: {$type}");
    }
}
