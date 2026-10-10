<?php

declare(strict_types=1);

namespace Cronwatch;

use Cronwatch\Cron\Cron;
use Cronwatch\Cron\CronError;
use Cronwatch\Cron\Zone;

/**
 * Schedules: "0 2 * * *" (cron, five or six fields), "@hourly", or "every
 * 5m". Due times, deadlines, and what a run covers, as schedule.ts has them.
 * Fire times come from the port of croner in Cron/, so a Node, a Ruby, a
 * Python, and a PHP process sharing one store agree on every due time.
 *
 * @internal
 */
final class Schedule
{
    /** How early a run may start and still count for the fire it was meant for. */
    public const EARLY_SLACK_MS = 60_000;

    /** @var array<string, ParsedSchedule> */
    private static array $cache = [];

    /**
     * Parsed once per (schedule, timezone) pair and cached. Without a
     * timezone the expression is read in PHP's default timezone
     * (date_default_timezone_get()), like crontab reads the system's. Vercel
     * and GitHub Actions run their crons in UTC, so pass "UTC" for those.
     *
     * @throws \InvalidArgumentException for a schedule that is neither, with the SDK's message
     */
    public static function parse(string $schedule, ?string $timezone = null): ParsedSchedule
    {
        $key = ($timezone ?? '') . '|' . $schedule;
        if (isset(self::$cache[$key])) {
            return self::$cache[$key];
        }
        $text = Js::trim($schedule);
        if (preg_match('/^every[' . Js::WHITESPACE . ']+([^\n\r\x{2028}\x{2029}]+)$/iuD', $text, $every) === 1) {
            $everyMs = Duration::parse($every[1], 'schedule interval');
            if ($everyMs < 1000) {
                throw new \InvalidArgumentException("schedule \"{$schedule}\" is shorter than one second");
            }
            $parsed = new ParsedSchedule(ParsedSchedule::INTERVAL, $text, everyMs: $everyMs);
        } else {
            try {
                $cron = new Cron($text, $timezone === '' ? null : $timezone);
            } catch (CronError $error) {
                throw new \InvalidArgumentException("schedule \"{$schedule}\" is not a cron expression or \"every <duration>\": {$error->getMessage()}");
            }
            $parsed = new ParsedSchedule(ParsedSchedule::CRON, $text, $timezone === '' ? null : $timezone, cron: $cron);
        }
        // A long-running worker parses a handful of schedules; the bound only
        // keeps one fed endless distinct schedules from growing without end.
        if (count(self::$cache) >= 1000) {
            self::$cache = [];
        }
        return self::$cache[$key] = $parsed;
    }

    /**
     * Four hundred Gregorian years: 146,097 days, a whole number of weeks,
     * after which the calendar repeats date for date and weekday for weekday.
     */
    private const CYCLE_MS = 146_097 * 86_400_000;
    /** Date.UTC(400, 0, 1). croner misreads a year below 100, so earlier times are asked a cycle or more later. */
    private const CRONER_FIRST_MS = -49_544_438_400_000;
    /** Date.UTC(2800, 0, 1). croner finds no fire past the year 3000, so later times are asked a cycle or more earlier. */
    private const CRONER_LAST_MS = 26_192_246_400_000;

    /**
     * The next `n` fires of a cron strictly after `from`, which lies within
     * the years 1 to 9999, dropping any after 9999. A time croner cannot
     * answer for is moved by whole 400-year cycles into the years it can, and
     * its fires moved back, as schedule.ts's runsAfter does, so this port
     * agrees with Node's answers: a time before 400 goes forward, into the
     * same local mean time every zone kept then, and one from 2800 goes back,
     * to where the zone's present rules already hold.
     *
     * @return list<int>
     */
    private static function runsAfter(Cron $cron, int $n, int $from): array
    {
        $shift = 0;
        if ($from < self::CRONER_FIRST_MS) {
            $shift = intdiv(self::CRONER_FIRST_MS - $from + self::CYCLE_MS - 1, self::CYCLE_MS) * self::CYCLE_MS;
        } elseif ($from >= self::CRONER_LAST_MS) {
            $shift = -(intdiv($from - self::CRONER_LAST_MS, self::CYCLE_MS) + 1) * self::CYCLE_MS;
        }
        $out = [];
        foreach ($cron->nextRuns($n, $from + $shift) as $fire) {
            $t = $fire - $shift;
            if ($t > Js::LAST_DATE_MS) {
                break;
            }
            $out[] = $t;
        }
        return $out;
    }

    /**
     * A stored time as a cron's fires are counted from it. A start read from
     * a foreign or damaged row can be any number: one before the year 1
     * counts from just before its first millisecond, so the first fire of the
     * year 1 is the next one, and one at or after the last millisecond of
     * 9999 has no fire after it at all (null). No fire is ever after 9999.
     */
    private static function countFrom(int|float $from): ?int
    {
        if ($from >= Js::LAST_DATE_MS) {
            return null;
        }
        return $from >= Js::FIRST_DATE_MS ? (int) Js::floor($from) : Js::FIRST_DATE_MS - 1;
    }

    /**
     * The first fire strictly after `from`, or null when the cron never fires
     * again. Croner answers with times in the past when asked from inside the
     * hour that repeats when clocks go back, so its answers are filtered, and
     * a stretch of nothing but past times is stepped over an hour at a time.
     */
    private static function fireAfter(ParsedSchedule $parsed, int|float $from): ?int
    {
        $cron = self::cronOf($parsed);
        $start = self::countFrom($from);
        if ($start === null) {
            return null;
        }
        // A fraction counts from its floor, but a fire must still be after the time itself.
        $after = $from >= Js::FIRST_DATE_MS ? $from : $start;
        $probe = $start;
        for ($attempt = 0; $attempt < 4; $attempt++) {
            $runs = self::runsAfter($cron, 8, $probe);
            if ($runs === []) {
                return null;
            }
            foreach ($runs as $fire) {
                if ($fire > $after) {
                    return $fire;
                }
            }
            $probe += 3_600_000;
        }
        return null;
    }

    private static function cronOf(ParsedSchedule $parsed): Cron
    {
        return $parsed->cron ?? throw new \InvalidArgumentException("schedule \"{$parsed->source}\" was not made by Schedule::parse");
    }

    /**
     * Every fire of a cron strictly after `from` and at or before `to`,
     * ascending, or null when there are more than `limit`. Asks for fires in
     * batches and drops any that do not move forward (see fireAfter).
     *
     * @return list<int>|null
     */
    public static function firesBetween(ParsedSchedule $parsed, int $from, int $to, int $limit): ?array
    {
        $cron = self::cronOf($parsed);
        $out = [];
        $start = self::countFrom($from);
        if ($start === null) {
            return $out;
        }
        $probe = $start;
        $last = $start;
        for ($guard = 0; $guard < 1000; $guard++) {
            $batch = self::runsAfter($cron, min($limit + 1 - count($out), 24), $probe);
            if ($batch === []) {
                return $out;
            }
            foreach ($batch as $t) {
                if ($t <= $last) {
                    continue;
                }
                if ($t > $to) {
                    return $out;
                }
                $out[] = $t;
                $last = $t;
                if (count($out) > $limit) {
                    return null;
                }
            }
            $end = $batch[count($batch) - 1];
            $probe = $end > $probe ? $end : $probe + 3_600_000;
        }
        return $out;
    }

    /** The next time the schedule fires strictly after `from`. For an interval, counted from the last run when there is one. */
    public static function nextFire(ParsedSchedule $parsed, int|float $from, int|float|null $lastRunAt): int|float|null
    {
        if ($parsed->kind === ParsedSchedule::INTERVAL) {
            return ($lastRunAt ?? $from) + $parsed->everyMs;
        }
        return self::fireAfter($parsed, $from);
    }

    /**
     * When the schedule next wants a run, given the last one. For a cron that
     * is the first fire the last run does not already cover; with no run yet,
     * the first fire at or after registration. For an interval it is the last
     * run's start (or registration) plus the interval. Null for a cron that
     * never fires again.
     *
     * Counting forward from the last run, rather than back from now, is what
     * lets a job whose period is shorter than its grace be missed at all, and
     * it works for a cron that fires once a year or less.
     */
    public static function expectation(ParsedSchedule $parsed, int|float|null $lastRunAt, int|float $registeredAt, int|float $graceMs): ?Expectation
    {
        if ($parsed->kind === ParsedSchedule::INTERVAL) {
            $dueAt = ($lastRunAt ?? $registeredAt) + $parsed->everyMs;
        } elseif ($lastRunAt === null) {
            $dueAt = self::fireAfter($parsed, $registeredAt - 1);
        } else {
            $dueAt = self::dueAfterRun($parsed, $lastRunAt);
        }
        return $dueAt === null ? null : new Expectation($dueAt, $dueAt + $graceMs);
    }

    /**
     * The first fire that a run starting at `startedAt` does not cover. A
     * start before the year 1 covers none of them, so the first fire of the
     * year 1 is due; after 9999 there is none (see countFrom).
     */
    private static function dueAfterRun(ParsedSchedule $parsed, int|float $startedAt): ?int
    {
        // A fire at or before the start is covered by the run itself.
        $next = self::fireAfter($parsed, $startedAt);
        if ($next === null) {
            return null;
        }
        $following = self::fireAfter($parsed, $next);
        $covers = self::runCovers($startedAt, $next, $following) || self::inSpringForwardGap($parsed, $startedAt, $next);
        return $covers ? $following : $next;
    }

    /**
     * Whether a run starting at `startedAt` covers the fire at `dueAt`. A
     * minute of slack before the tick absorbs schedulers that fire a touch
     * early. When the fire after `dueAt` is known, the slack is at most half
     * the gap between the two, so one run of an every-minute cron never
     * covers two fires.
     */
    public static function runCovers(int|float $startedAt, int|float $dueAt, int|float|null $followingAt = null): bool
    {
        $slack = $followingAt === null ? self::EARLY_SLACK_MS : min(self::EARLY_SLACK_MS, Js::floor(($followingAt - $dueAt) / 2));
        return $startedAt >= $dueAt - $slack;
    }

    /**
     * On the night clocks spring forward, a fire whose local time does not
     * exist (02:30 when 02:00 jumps to 03:00) is moved by croner to the same
     * distance past the jump (03:30), while vixie cron runs it at the jump
     * itself (03:00). A run that starts at or after the jump, and before the
     * first fire after it when that fire lies within one gap of it, is taken
     * to cover that fire, so neither scheduler's run is reported as missed.
     */
    private static function inSpringForwardGap(ParsedSchedule $parsed, int|float $startedAt, int $fireAt): bool
    {
        $lookback = 3 * 3_600_000;
        // Every zone kept its local mean time, with no clock change, in the year 1.
        if ($fireAt - $lookback < Js::FIRST_DATE_MS) {
            return false;
        }
        $after = self::utcOffset($fireAt, $parsed->timezone);
        $before = self::utcOffset($fireAt - $lookback, $parsed->timezone);
        $gap = $after - $before;
        if ($gap <= 0) {
            return false;
        }
        // Find the jump: the first minute in the window with the later offset.
        $lo = $fireAt - $lookback;
        $hi = $fireAt;
        while ($hi - $lo > 60_000) {
            $mid = $lo + intdiv($hi - $lo, 2);
            if (self::utcOffset($mid, $parsed->timezone) === $after) {
                $hi = $mid;
            } else {
                $lo = $mid;
            }
        }
        $jumpAt = Js::div($hi, 60_000) * 60_000;
        if ($fireAt - $jumpAt >= $gap || $startedAt < $jumpAt - self::EARLY_SLACK_MS || $startedAt >= $fireAt) {
            return false;
        }
        // Only the first fire after the jump can be a moved one; a cron that
        // also fires at the jump (every 10 minutes, say) was not moved at all.
        return self::fireAfter($parsed, $jumpAt - 1) === $fireAt;
    }

    /** Milliseconds the zone's wall clock is ahead of UTC at `at`. */
    private static function utcOffset(int $at, ?string $timezone): int
    {
        return Zone::offset(Js::div($at, 1000), $timezone) * 1000;
    }
}
