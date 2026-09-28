<?php

declare(strict_types=1);

namespace Cronwatch\Cron;

use Cronwatch\Js;

/**
 * Croner's CronDate: a wall-clock time whose fields are moved forward to the
 * next match, a field at a time, spilling into the next month or year as
 * croner does, with its habits: a day the month does not have rolls over, a
 * wall-clock time in a spring-forward gap moves forward by the gap, and a
 * time that happens twice is the earlier one. Month is 0 based.
 *
 * @internal
 */
final class CronDate
{
    private const DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

    /** [field, the field above it, offset from a field value to its pattern index] */
    private const ORDER = [['month', 'year', 0], ['day', 'month', -1], ['hour', 'day', 0], ['minute', 'hour', 0], ['second', 'minute', 0]];

    public int $year = 0;
    public int $month = 0;
    public int $day = 0;
    public int $hour = 0;
    public int $minute = 0;
    public int $second = 0;
    public int $ms = 0;

    public function __construct(public readonly ?string $tz)
    {
    }

    /** new CronDate(new Date(at), tz). */
    public static function fromMs(int $at, ?string $tz): self
    {
        $date = new self($tz);
        $sec = Js::div($at, 1000);
        [$year, $month, $day, $hour, $minute, $second] = Zone::wall($sec, $tz);
        $date->year = $year;
        $date->month = $month - 1;
        $date->day = $day;
        $date->hour = $hour;
        $date->minute = $minute;
        $date->second = $second;
        $date->ms = $at - $sec * 1000;
        return $date;
    }

    /** Croner's getLastDayOfMonth, month 0 based. */
    public static function lastDayOfMonth(int $year, int $month): ?int
    {
        if ($month !== 1) {
            return $month >= 0 && $month < 12 ? self::DAYS_IN_MONTH[$month] : null;
        }
        return Js::civilFromDays(Js::div(Js::dateUtc($year, $month + 1, 0), 86_400_000))[2];
    }

    /** new Date(Date.UTC(year, month, day)).getUTCDay(), month 0 based and free to overflow. 0 is Sunday. */
    private static function weekday(int $year, int $month, int $day): int
    {
        return Js::mod(Js::div(Js::dateUtc($year, $month, $day), 86_400_000) + 4, 7);
    }

    private function apply(): bool
    {
        $m = $this->month;
        if (
            $m > 11 || $m < 0 || $this->day > self::DAYS_IN_MONTH[$m] || $this->day < 1
            || $this->hour > 59 || $this->minute > 59 || $this->second > 59
            || $this->hour < 0 || $this->minute < 0 || $this->second < 0
        ) {
            $at = Js::dateUtc($this->year, $this->month, $this->day, $this->hour, $this->minute, $this->second, $this->ms);
            $sec = Js::div($at, 1000);
            $this->ms = $at - $sec * 1000;
            $days = Js::div($sec, 86_400);
            $rest = $sec - $days * 86_400;
            [$year, $month, $day] = Js::civilFromDays($days);
            $this->year = $year;
            $this->month = $month - 1;
            $this->day = $day;
            $this->hour = intdiv($rest, 3600);
            $this->minute = intdiv($rest % 3600, 60);
            $this->second = $rest % 60;
            return true;
        }
        return false;
    }

    private function lastWeekday(int $year, int $month): int
    {
        $last = self::lastDayOfMonth($year, $month) ?? 0;
        $wd = self::weekday($year, $month, $last);
        return $wd === 0 ? $last - 2 : ($wd === 6 ? $last - 1 : $last);
    }

    private function nearestWeekday(int $year, int $month, int $day): int
    {
        $last = self::lastDayOfMonth($year, $month);
        if ($last !== null && $day > $last) {
            return -1;
        }
        $wd = self::weekday($year, $month, $day);
        if ($wd === 0) {
            return $day === $last ? $day - 2 : $day + 1;
        }
        if ($wd === 6) {
            return $day === 1 ? $day + 2 : $day - 1;
        }
        return $day;
    }

    private function isNthWeekday(int $year, int $month, int $day, int $bits): bool
    {
        $wd = self::weekday($year, $month, $day);
        $count = 0;
        for ($d = 1; $d <= $day; $d++) {
            if (self::weekday($year, $month, $d) === $wd) {
                $count++;
            }
        }
        if (($bits & CronPattern::ANY) && $count >= 1 && $count <= count(CronPattern::NTH) && (CronPattern::NTH[$count - 1] & $bits)) {
            return true;
        }
        if ($bits & CronPattern::LAST) {
            $last = self::lastDayOfMonth($year, $month) ?? 0;
            for ($d = $day + 1; $d <= $last; $d++) {
                if (self::weekday($year, $month, $d) === $wd) {
                    return false;
                }
            }
            return true;
        }
        return false;
    }

    /** 1: the field already matches, 2: moved forward to a match, 3: none left. */
    private function findNext(CronPattern $pattern, string $kind, int $offset): int
    {
        $before = $this->{$kind};
        $table = $pattern->{$kind};
        $size = count($table);
        $last = $pattern->lastDayOfMonth ? self::lastDayOfMonth($this->year, $this->month) : null;
        $firstWeekday = !$pattern->starDOW && $kind === 'day' ? self::weekday($this->year, $this->month, 1) : 0;
        for ($u = $before + $offset; $u < $size; $u++) {
            $d = $u >= 0 ? $table[$u] : 0;
            if ($kind === 'day' && !$d) {
                foreach ($pattern->nearestWeekdays as $c => $nearest) {
                    if ($nearest) {
                        $m = $this->nearestWeekday($this->year, $this->month, $c - $offset);
                        if ($m === -1) {
                            continue;
                        }
                        if ($m === $u - $offset) {
                            $d = 1;
                            break;
                        }
                    }
                }
            }
            if ($kind === 'day' && $pattern->lastWeekday && $u - $offset === $this->lastWeekday($this->year, $this->month)) {
                $d = 1;
            }
            if ($kind === 'day' && $pattern->lastDayOfMonth && $u - $offset === $last) {
                $d = 1;
            }
            if ($kind === 'day' && !$pattern->starDOW) {
                $bits = $pattern->dayOfWeek[Js::mod($firstWeekday + ($u - $offset - 1), 7)];
                if ($bits && ($bits & CronPattern::ANY)) {
                    $bits = $this->isNthWeekday($this->year, $this->month, $u - $offset, $bits) ? 1 : 0;
                } elseif ($bits) {
                    throw new CronError("CronDate: Invalid value for dayOfWeek encountered. {$bits}");
                }
                if ($pattern->useAndLogic) {
                    $d = $d ? $bits : $d;
                } elseif (!$pattern->starDOM) {
                    $d = $d ?: $bits;
                } else {
                    $d = $d ? $bits : $d;
                }
            }
            if ($d) {
                $this->{$kind} = $u - $offset;
                return $before !== $this->{$kind} ? 2 : 1;
            }
        }
        return 3;
    }

    private function recurse(CronPattern $pattern): ?self
    {
        $level = 0;
        $years = 10_000;
        while (true) {
            if ($level === 0 && !$pattern->starYear) {
                if ($this->year >= 0 && $this->year < $years && !$pattern->hasYear($this->year)) {
                    $found = -1;
                    for ($y = $this->year + 1; $y < $years; $y++) {
                        if ($pattern->hasYear($y)) {
                            $found = $y;
                            break;
                        }
                    }
                    if ($found === -1) {
                        return null;
                    }
                    $this->year = $found;
                    $this->month = 0;
                    $this->day = 1;
                    $this->hour = $this->minute = $this->second = $this->ms = 0;
                }
                if ($this->year >= 10_000) {
                    return null;
                }
            }
            // A level below 0 counts from the end, as a negative index does in the Python port.
            [$kind, $above, $offset] = self::ORDER[$level < 0 ? $level + count(self::ORDER) : $level];
            $n = $this->findNext($pattern, $kind, $offset);
            if ($n > 1) {
                for ($i = $level + 1; $i < count(self::ORDER); $i++) {
                    $field = self::ORDER[$i < 0 ? $i + count(self::ORDER) : $i];
                    $this->{$field[0]} = -$field[2];
                }
                if ($n === 3) {
                    $this->{$above} = $this->{$above} + 1;
                    $this->{$kind} = -$offset;
                    $this->apply();
                    if ($level === 0 && !$pattern->starYear) {
                        while ($this->year >= 0 && $this->year < $years && !$pattern->hasYear($this->year)) {
                            $this->year++;
                        }
                        if ($this->year >= 10_000 || $this->year >= $years) {
                            return null;
                        }
                    }
                    $level = 0;
                    continue;
                }
                if ($this->apply()) {
                    $level--;
                    continue;
                }
            }
            $level++;
            if ($level >= count(self::ORDER)) {
                return $this;
            }
            if ($pattern->starYear ? $this->year >= 3000 : $this->year >= 10_000) {
                return null;
            }
        }
    }

    public function increment(CronPattern $pattern): ?self
    {
        $this->second++;
        $this->ms = 0;
        $this->apply();
        return $this->recurse($pattern);
    }

    /** getDate(false).getTime(): the instant this wall-clock time names. */
    public function timeMs(): int
    {
        return Zone::toUtc([$this->year, $this->month + 1, $this->day, $this->hour, $this->minute, $this->second], $this->tz) * 1000;
    }
}
