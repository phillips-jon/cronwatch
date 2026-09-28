<?php

declare(strict_types=1);

namespace Cronwatch;

use Cronwatch\Cron\Cron;
use Cronwatch\Cron\CronError;
use Cronwatch\Cron\Zone;

/**
 * Schedules: "0 2 * * *" (cron, five or six fields), "@hourly", or "every
 * 5m". Due times, deadlines and what a run covers, as schedule.ts has them.
 * Fire times come from the port of croner in Cron/, so a Node, a Ruby, a
 * Python and a PHP process sharing one store agree on every due time.
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
     * The first fire strictly after `from`, or null when the cron never fires
     * again. Croner answers with times in the past when asked from inside the
     * hour that repeats when clocks go back, so its answers are filtered, and
     * a stretch of nothing but past times is stepped over an hour at a time.
     */
    private static function fireAfter(ParsedSchedule $parsed, int|float $from): ?int
    {
        $cron = self::cronOf($parsed);
        $probe = Js::floor($from);
        for ($attempt = 0; $attempt < 4; $attempt++) {
            $runs = $cron->nextRuns(8, (int) $probe);
            if ($runs === []) {
                return null;
            }
            foreach ($runs as $fire) {
                if ($fire > $from) {
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
        $probe = $from;
        $last = $from;
        for ($guard = 0; $guard < 1000; $guard++) {
            $batch = $cron->nextRuns(min($limit + 1 - count($out), 24), $probe);
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

    /** The first fire that a run starting at `startedAt` does not cover. */
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
