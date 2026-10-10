<?php

declare(strict_types=1);

namespace Cronwatch\Web;

use Cronwatch\Duration;
use Cronwatch\Evaluate;
use Cronwatch\Format;
use Cronwatch\JobSummary;
use Cronwatch\Js;
use Cronwatch\ParsedSchedule;
use Cronwatch\Run;
use Cronwatch\Schedule;

/**
 * The dashboard's timelines, markup for markup the SDK's
 * routes/timeline.ts: one lane per job (or per day, on a job's page), drawn
 * on the server as inline SVG so the page needs no script.
 *
 * Every time a job was due is a faint tick, worked out from its schedule
 * with the same functions the checks use (firesBetween and expectation), so
 * the lane shows the cadence the job is meant to keep. Every run it recorded
 * is a solid mark on top, as wide as it took and coloured by how it ended. A
 * slot the check has reported missed is a dashed box. The empty part of a
 * lane carries a short note about anything open, and a visually hidden list
 * says the same things in words.
 *
 * Every time is UTC: without script the page cannot know the viewer's zone.
 * A lane is given as ['job' => JobSummary, 'runs' => list<Run>, 'complete' => bool]
 * (complete is false when older runs exist that were not read), and a span as
 * ['from' => ms, 'to' => ms, 'now' => ms].
 *
 * @internal
 */
final class Timeline
{
    public const HOUR = 3_600_000;
    public const DAY = 24 * self::HOUR;

    /** The board's span: the last day, plus a few hours ahead so what is due soon shows. */
    public const BOARD_BEHIND_MS = self::DAY;
    public const BOARD_AHEAD_MS = 3 * self::HOUR;
    /** How many jobs the board's timeline draws. The table below it lists every job. */
    public const BOARD_LANES = 30;
    /**
     * Runs read for a lane when the twenty the table reads start inside the
     * span, so a frequent job's lane is not cut short. Older runs than this
     * are shown as not loaded rather than as absent.
     */
    public const BOARD_RUNS = 200;
    /** How many days a job's page draws. */
    public const WEEK_DAYS = 7;

    /** Width of a lane in SVG units. Lanes stretch to fit, so strokes do not scale. */
    private const W = 1000;
    /** A lane with more due times than this shows its cadence as a dotted line instead. */
    private const MAX_TICKS = 330;
    /** More missed slots than this are drawn as one dashed band. */
    private const MAX_BOXES = 8;
    /** The narrowest a missed box is drawn, in SVG units. */
    private const MIN_BOX = 10;

    private const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    private const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    public const STATE_CLASS = ['healthy' => 'ok', 'late' => 'warn', 'failing' => 'bad', 'stuck' => 'bad', 'silenced' => 'muted', 'never_ran' => 'muted'];

    /** "22:42", in UTC. */
    public static function clock(int|float $t): string
    {
        return substr(Js::iso(self::instant($t)), 11, 5);
    }

    /** "Sat 26 Sep", in UTC. */
    public static function dayLabel(int|float $t): string
    {
        [, $month, $day, $weekday] = self::date($t);
        return self::WEEKDAYS[$weekday] . " {$day} " . self::MONTHS[$month - 1];
    }

    /**
     * "22:42" on the same UTC day as `now`, otherwise "25 Sep 22:42", and
     * "1 Jan 0001 02:00" in another UTC year. A time before the year 1 or
     * after 9999 (a start read from a foreign or damaged row) is "before 1
     * Jan 0001 00:00" or "after 31 Dec 9999 23:59".
     */
    public static function when(int|float $t, int|float $now): string
    {
        if ($t > Js::LAST_DATE_MS) {
            return 'after 31 Dec 9999 23:59';
        }
        if (!($t >= Js::FIRST_DATE_MS)) {
            return 'before 1 Jan 0001 00:00';
        }
        if (floor($t / self::DAY) == floor($now / self::DAY)) {
            return self::clock($t);
        }
        [$year, $month, $day] = self::date($t);
        // In another UTC year than now's, the year too: "1 Jan 0001 02:00".
        $other = $year === self::date($now)[0] ? '' : ' ' . str_pad((string) $year, 4, '0', STR_PAD_LEFT);
        return "{$day} " . self::MONTHS[$month - 1] . $other . ' ' . self::clock($t);
    }

    /** A time as new Date(t) holds it: whole milliseconds, cut toward zero. */
    private static function instant(int|float $t): int
    {
        return is_int($t) ? $t : (int) ($t < 0 ? ceil($t) : floor($t));
    }

    /** @return array{int, int, int, int} year, month 1 to 12, day, weekday 0 for Sunday */
    private static function date(int|float $t): array
    {
        $days = Js::div(self::instant($t), self::DAY);
        [$year, $month, $day] = Js::civilFromDays($days);
        return [$year, $month, $day, Js::mod($days + 4, 7)];
    }

    /** The job's schedule, parsed, or null when it has none or it no longer parses. */
    public static function parsedSchedule(JobSummary $job): ?ParsedSchedule
    {
        $schedule = $job->definition->get('schedule');
        if (!Text::truthy($schedule)) {
            return null;
        }
        try {
            $timezone = $job->definition->get('timezone');
            return Schedule::parse((string) $schedule, Text::truthy($timezone) ? (string) $timezone : null);
        } catch (\Throwable) {
            return null;
        }
    }

    private static function safely(callable $fn, mixed $fallback): mixed
    {
        try {
            return $fn();
        } catch (\Throwable) {
            return $fallback;
        }
    }

    private static function isOpen(JobSummary $job, string $condition): bool
    {
        return in_array($condition, $job->open, true);
    }

    private static function f(int|float $n): string
    {
        return Text::toFixed($n, 1);
    }

    /** Animation delay for a mark at x, so marks arrive in time order, left to right. */
    private static function delay(int|float $x, int|float $base = 80, int|float $perUnit = 0.75): string
    {
        return '--d:' . Js::number(Js::round($base + max(0, $x) * $perUnit)) . 'ms';
    }

    /**
     * When the job was due within `from` to `to`. A cron's fires come from
     * firesBetween. An interval is due one period after each run started, and
     * after the last run once a period for as long as nothing runs (the times
     * a missed interval job keeps being asked for); with no run yet, from its
     * next expected time.
     *
     * @param list<Run> $runs
     * @return array{times: list<int|float>, dense: bool} dense when there are too many to draw one by one; times is then empty
     */
    public static function dueTimes(JobSummary $job, ?ParsedSchedule $parsed, array $runs, int|float $from, int|float $to): array
    {
        if ($parsed === null) {
            return ['times' => [], 'dense' => false];
        }
        if ($parsed->kind === ParsedSchedule::INTERVAL) {
            $every = $parsed->everyMs;
            if (($to - $from) / $every > self::MAX_TICKS) {
                return ['times' => [], 'dense' => true];
            }
            $starts = array_map(fn (Run $r) => $r->startedAt, $runs);
            sort($starts);
            $times = [];
            foreach ($starts as $start) {
                $t = $start + $every;
                if ($t >= $from && $t <= $to) {
                    $times[(string) $t] = $t;
                }
            }
            $t = $starts !== [] ? $starts[count($starts) - 1] + $every : $job->nextExpectedAt;
            if ($t !== null) {
                if ($t < $from) {
                    $t += ceil(($from - $t) / $every) * $every;
                }
                for (; $t <= $to; $t += $every) {
                    $times[(string) $t] = $t;
                }
            }
            $times = array_values($times);
            sort($times);
            return ['times' => $times, 'dense' => false];
        }
        $times = self::safely(fn () => Schedule::firesBetween($parsed, (int) $from - 1, (int) $to, self::MAX_TICKS), []);
        return $times === null ? ['times' => [], 'dense' => true] : ['times' => $times, 'dense' => false];
    }

    /**
     * The slot a missed job was due at, the one the check reported: the
     * first fire its last run does not cover (expectation(), as onCheck works
     * it out). A job that never ran has no run to count from, so the latest
     * due time whose grace has passed stands in. Null when missed is not open.
     *
     * @param list<int|float> $times
     */
    public static function missedAt(JobSummary $job, ?ParsedSchedule $parsed, array $times, int|float $now): int|float|null
    {
        if ($parsed === null || !self::isOpen($job, 'missed')) {
            return null;
        }
        $grace = self::safely(fn () => Evaluate::graceMs($job->definition), 0);
        $last = $job->lastRun?->startedAt;
        if ($last !== null) {
            return self::safely(fn () => Schedule::expectation($parsed, $last, $last, $grace)?->dueAt, null);
        }
        $past = array_values(array_filter($times, fn ($t) => $t + $grace < $now));
        return $past === [] ? null : $past[count($past) - 1];
    }

    private static function toneOf(Run $run, JobSummary $job, int|float $now): string
    {
        if ($run->status === 'running') {
            return self::safely(fn () => Evaluate::isStuck($job->definition, $run, $now), false) ? 'stuck' : 'running';
        }
        if ($run->status === 'failed') {
            return 'bad';
        }
        if ($run->status === 'timeout') {
            return 'timeout';
        }
        $latest = $job->lastRun?->id === $run->id;
        return $latest && (self::isOpen($job, 'over_budget') || self::isOpen($job, 'under_floor') || self::isOpen($job, 'slow')) ? 'warn' : 'ok';
    }

    private static function timeoutText(JobSummary $job): string
    {
        return self::safely(fn () => Duration::format(Evaluate::timeoutMs($job->definition)), 'configured');
    }

    /** One run, as its tooltip says it. */
    private static function describeRun(Run $run, string $tone, JobSummary $job, int|float $now): string
    {
        $at = self::when($run->startedAt, $now) . ' UTC';
        if ($tone === 'running') {
            return "running since {$at}, " . Duration::format($now - $run->startedAt) . ' so far';
        }
        if ($tone === 'stuck') {
            return "running since {$at}, past its " . self::timeoutText($job) . ' timeout';
        }
        $took = $run->durationMs !== null ? ', took ' . Duration::format($run->durationMs) : '';
        $extra = $tone === 'warn' ? (self::isOpen($job, 'over_budget') ? ', over budget' : (self::isOpen($job, 'under_floor') ? ', under floor' : ', slow')) : '';
        return "{$run->status} at {$at}{$took}{$extra}";
    }

    /** @return list<string> the metrics of the job's last run that went over their ceilings */
    private static function overCeilings(JobSummary $job): array
    {
        $metrics = $job->lastRun?->metrics ?? [];
        $over = [];
        foreach (Text::entries($job->definition->get('budget')) as [$key, $limit]) {
            $value = $metrics[$key] ?? null;
            if (Js::isNumber($value) && Js::isNumber($limit) && $value > $limit) {
                $over[] = $key;
            }
        }
        return $over;
    }

    /** @return list<string> the metrics of the job's last run under their floors, or at 0 or less without one */
    private static function underFloors(JobSummary $job): array
    {
        $floors = $job->definition->get('floor');
        $floors = is_array($floors) ? $floors : [];
        $under = [];
        foreach (Text::entries($job->lastRun?->metrics ?? []) as [$key, $value]) {
            $floor = $floors[$key] ?? null;
            if (Js::isNumber($value) && ($floor !== null ? $value < $floor : $value <= 0)) {
                $under[] = $key;
            }
        }
        return $under;
    }

    /** What is worth saying about the job in a few words, or null when all is well. */
    public static function laneNote(JobSummary $job, int|float|null $missed, int|float $now): ?string
    {
        $last = $job->lastRun;
        if ($job->silencedUntil !== null && $job->silencedUntil > $now) {
            return 'silenced until ' . self::when($job->silencedUntil, $now);
        }
        if (self::isOpen($job, 'missed')) {
            return $missed !== null ? 'due ' . self::when($missed, $now) . ', nothing ran' : 'overdue, nothing ran';
        }
        if ($last?->status === 'running') {
            $stuck = self::safely(fn () => Evaluate::isStuck($job->definition, $last, $now), false);
            $since = 'running since ' . self::when($last->startedAt, $now);
            return $stuck ? "{$since}, past its " . self::timeoutText($job) . ' timeout' : $since;
        }
        if ($last?->status === 'failed') {
            $row = $job->consecutiveFailures > 1 ? ', ' . Js::number($job->consecutiveFailures) . ' in a row' : '';
            return 'failed at ' . self::when($last->startedAt, $now) . $row;
        }
        if ($last?->status === 'timeout') {
            return 'timed out at ' . self::when($last->startedAt, $now);
        }
        if (self::isOpen($job, 'stuck')) {
            return 'stuck';
        }
        if (self::isOpen($job, 'over_budget') && $last !== null) {
            $over = self::overCeilings($job);
            return 'went over budget' . ($over !== [] ? ' on ' . Format::andList($over) : '') . ' at ' . self::when($last->startedAt, $now);
        }
        if (self::isOpen($job, 'under_floor') && $last !== null) {
            $under = self::underFloors($job);
            return 'fell short' . ($under !== [] ? ' on ' . Format::andList($under) : '') . ' at ' . self::when($last->startedAt, $now);
        }
        if (self::isOpen($job, 'slow') && $last?->durationMs !== null) {
            return 'slow: took ' . Duration::format($last->durationMs);
        }
        if (self::isOpen($job, 'failed')) {
            return 'failing';
        }
        if ($last === null && $job->nextExpectedAt !== null) {
            return 'no runs yet, first due ' . self::when($job->nextExpectedAt, $now);
        }
        return null;
    }

    /**
     * Everything one lane shows: the marks, the note, and the same in words.
     *
     * @param array{job: JobSummary, runs: list<Run>, complete: bool} $input
     * @param array{from: int|float, to: int|float, now: int|float} $span
     * @return array{svg: string, note: string, words: string}
     */
    private static function lane(array $input, array $span, bool $nowInLane, string $label): array
    {
        $job = $input['job'];
        ['from' => $from, 'to' => $to, 'now' => $now] = $span;
        $w = self::W;
        $x = fn (int|float $t): int|float => min($w, max(0, (($t - $from) / ($to - $from)) * $w));
        $parsed = self::parsedSchedule($job);
        $due = self::dueTimes($job, $parsed, $input['runs'], $from, $to);
        $missed = self::missedAt($job, $parsed, $due['times'], $now);
        $grace = self::safely(fn () => Evaluate::graceMs($job->definition), 0);
        $name = $label;
        $busy = [];
        $inside = $nowInLane && $now > $from && $now < $to;

        $s = '<svg class="marks" viewBox="0 0 ' . $w . ' 24" preserveAspectRatio="none" aria-hidden="true" focusable="false">';
        if ($inside) {
            $s .= '<rect class="ahead" x="' . self::f($x($now)) . '" y="0" width="' . self::f($w - $x($now)) . '" height="24"/>';
        }
        $s .= '<line class="base" x1="0" y1="12" x2="' . $w . '" y2="12"/>';

        $inSpan = array_values(array_filter($input['runs'], fn (Run $r) => $r->startedAt <= $to && ($r->finishedAt ?? $now) >= $from));
        usort($inSpan, fn (Run $a, Run $b) => $a->startedAt <=> $b->startedAt);
        if (!$input['complete'] && $input['runs'] !== []) {
            $oldest = min(array_map(fn (Run $r) => $r->startedAt, $input['runs']));
            if ($oldest > $from) {
                $title = Text::h("{$name}: runs before " . self::when($oldest, $now) . ' UTC are not loaded here');
                $s .= '<rect class="unloaded" x="0" y="4" width="' . self::f($x($oldest)) . '" height="16"><title>' . $title . '</title></rect>';
            }
        }

        if ($due['dense']) {
            $title = Text::h("{$name}: due " . Text::text($job->definition->get('schedule') ?? '') . ', too often to mark each time');
            $s .= '<line class="cadence" x1="0" y1="12" x2="' . $w . '" y2="12"><title>' . $title . '</title></line>';
        }
        foreach ($due['times'] as $t) {
            $tx = $x($t);
            $s .= '<line class="tick' . ($t > $now ? ' ahead' : '') . '" x1="' . self::f($tx) . '" y1="6" x2="' . self::f($tx) . '" y2="18" style="' . self::delay($tx, 0, 0.45) . '"/>';
        }

        // Missed slots: the reported one and every later one whose grace has run out.
        if ($missed !== null && $missed <= $to) {
            $slots = $due['dense'] ? [] : array_values(array_filter($due['times'], fn ($t) => $t >= $missed && $t + $grace < $now));
            if (!in_array($missed, $slots) && $missed >= $from) {
                array_unshift($slots, $missed);
            }
            $several = count($slots) > 1 ? ' (' . count($slots) . ' slots in this span)' : '';
            $title = Text::h("{$name}: due " . self::when($missed, $now) . " UTC, nothing started{$several}");
            if ($due['dense'] || count($slots) > self::MAX_BOXES) {
                $x1 = $x(max($missed, $from));
                $x2 = max($x($now), $x1 + self::MIN_BOX);
                $s .= '<rect class="missed" x="' . self::f($x1) . '" y="5" width="' . self::f($x2 - $x1) . '" height="14" style="' . self::delay($x1) . '"><title>' . $title . '</title></rect>';
                $busy[] = [$x1, $x2];
            } else {
                foreach ($slots as $t) {
                    if ($t < $from) {
                        continue;
                    }
                    $x1 = $x($t);
                    $width = max($x($t + $grace) - $x1, self::MIN_BOX);
                    $s .= '<rect class="missed" x="' . self::f($x1) . '" y="5" width="' . self::f($width) . '" height="14" style="' . self::delay($x1) . '"><title>' . $title . '</title></rect>';
                    $busy[] = [$x1, $x1 + $width];
                }
            }
        }

        foreach ($inSpan as $run) {
            $tone = self::toneOf($run, $job, $now);
            // A zero-width rect is not drawn at all; its stroke gives short runs their width.
            $x1 = $x($run->startedAt);
            $x2 = max($x($run->finishedAt ?? $now), $x1 + 0.5);
            $title = Text::h("{$name}: " . self::describeRun($run, $tone, $job, $now));
            $s .= '<rect class="run ' . $tone . '" x="' . self::f($x1) . '" y="5" width="' . self::f($x2 - $x1) . '" height="14" style="' . self::delay($x1) . '"><title>' . $title . '</title></rect>';
            $busy[] = [$x1, $x2];
        }

        if ($inside) {
            $s .= '<line class="nowline" x1="' . self::f($x($now)) . '" y1="0" x2="' . self::f($x($now)) . '" y2="24"/>';
        }
        $s .= '</svg>';

        // The note goes wherever the lane is actually empty, so it never sits
        // on the marks it describes; it is cut short with an ellipsis when narrow.
        $text = self::laneNote($job, $missed, $now);
        $note = '';
        if ($text !== null && $text !== '') {
            $nowX = $x($now);
            $lo = $busy !== [] ? min(array_map(fn (array $b) => $b[0], $busy)) : $nowX;
            $hi = $busy !== [] ? max(array_map(fn (array $b) => $b[1], $busy)) : $nowX;
            $right = $w - $hi >= $lo;
            $room = $right ? $w - $hi : $lo;
            if ($room > 90) {
                $edge = $right ? $hi + 14 : $lo - 14;
                $place = $right ? 'left:' . self::f($edge / 10) . '%' : 'right:' . self::f(100 - $edge / 10) . '%';
                $note = '<span class="note' . ($right ? '' : ' before') . '" style="' . $place . ';max-width:' . self::f(($room - 18) / 10) . '%">' . Text::h($text) . '</span>';
            }
        }

        return ['svg' => $s, 'note' => $note, 'words' => self::words($job, $inSpan, $due, $missed, $span, $text)];
    }

    /**
     * The lane in words, for anyone who cannot see it.
     *
     * @param list<Run> $runs
     * @param array{times: list<int|float>, dense: bool} $due
     * @param array{from: int|float, to: int|float, now: int|float} $span
     */
    private static function words(JobSummary $job, array $runs, array $due, int|float|null $missed, array $span, ?string $note): string
    {
        $parts = [];
        $schedule = $job->definition->get('schedule');
        if ($due['dense']) {
            $parts[] = 'due ' . Js::string($schedule);
        } elseif (Text::truthy($schedule)) {
            $n = count(array_filter($due['times'], fn ($t) => $t <= $span['now']));
            $parts[] = 'due ' . ($n === 0 ? 'no times' : ($n === 1 ? 'once' : "{$n} times")) . ' so far';
        }
        $count = count($runs);
        $ok = count(array_filter($runs, fn (Run $r) => $r->status === 'ok'));
        $summary = $count === 0 ? '' : ($ok === $count ? ($ok === 1 ? ', ok' : ', all ok') : ($ok > 0 ? ", {$ok} ok" : ''));
        $parts[] = "{$count} " . ($count === 1 ? 'run' : 'runs') . " recorded{$summary}";
        $bad = array_values(array_filter($runs, fn (Run $r) => $r->status === 'failed' || $r->status === 'timeout'));
        foreach (array_slice($bad, -5) as $r) {
            $parts[] = "{$r->status} at " . self::when($r->startedAt, $span['now']) . ' UTC after ' . Duration::format($r->durationMs ?? 0);
        }
        if ($missed !== null) {
            $parts[] = 'due at ' . self::when($missed, $span['now']) . ' UTC and nothing started';
        }
        if ($note !== null && $note !== '' && preg_match('/^(due |failed at|timed out)/', $note) !== 1) {
            $parts[] = $note;
        }
        return implode('; ', $parts);
    }

    /**
     * Grid lines and hour labels every `step`, on UTC boundaries.
     *
     * @param array{from: int|float, to: int|float, now: int|float} $span
     * @return array{string, string} the lines and the labels
     */
    private static function hours(array $span, int $step, bool $nowLabel): array
    {
        $w = self::W;
        $x = fn (int|float $t): int|float => (($t - $span['from']) / ($span['to'] - $span['from'])) * $w;
        $nowX = $x($span['now']);
        $lines = '';
        $labels = '';
        for ($t = ceil($span['from'] / $step) * $step; $t <= $span['to']; $t += $step) {
            $gx = $x($t);
            $lines .= '<i class="gl" style="left:' . self::f($gx / 10) . '%"></i>';
            $nearNow = $nowLabel && abs($gx - $nowX) < 70;
            if ($gx < 25 || $gx > $w - 25 || $nearNow) {
                continue;
            }
            $minor = Js::round($t / self::HOUR) % 6 !== 0;
            // On a phone the track is too narrow for a label this close to "now"; CSS hides it there.
            $near = $nowLabel && abs($gx - $nowX) < 170;
            $cls = implode(' ', array_keys(array_filter(['minor' => $minor, 'near' => $near])));
            $labels .= '<span class="' . $cls . '" style="left:' . self::f($gx / 10) . '%">' . self::clock($t) . '</span>';
        }
        if ($nowLabel && $span['now'] >= $span['from'] && $span['now'] <= $span['to']) {
            $labels .= '<span class="nowlabel" style="left:' . self::f($nowX / 10) . '%">now ' . self::clock($span['now']) . '</span>';
        }
        return [$lines, $labels];
    }

    /** The key under a timeline: a small sample of each mark and what it means. */
    private static function legend(): string
    {
        $key = fn (string $inner): string => '<svg class="key" viewBox="0 0 16 12" aria-hidden="true" focusable="false">' . $inner . '</svg>';
        $box = fn (string $cls): string => $key('<rect class="' . $cls . '" x="2" y="1" width="12" height="10"/>');
        $items = [
            [$key('<line class="tick" x1="8" y1="1" x2="8" y2="11"/>'), 'due'],
            [$box('run ok'), 'ran'],
            [$box('run bad'), 'failed'],
            [$box('run timeout'), 'timed out'],
            [$box('run warn'), 'over budget, under floor, or slow'],
            [$box('run running'), 'running'],
            [$box('missed'), 'missed'],
        ];
        return '<p class="legend" aria-hidden="true">' . implode('', array_map(fn (array $item) => "<span>{$item[0]}{$item[1]}</span>", $items)) . '</p>';
    }

    /**
     * The board's timeline: one lane per job across `span`, with a shared now
     * line and the first BOARD_LANES jobs only. `total` is how many jobs there
     * are in all, for the note when some are left out.
     *
     * @param list<array{job: JobSummary, runs: list<Run>, complete: bool}> $lanes
     * @param array{from: int|float, to: int|float, now: int|float} $span
     */
    public static function dayTimeline(array $lanes, array $span, string $base, int $total): string
    {
        [$lines, $labels] = self::hours($span, 3 * self::HOUR, true);
        $nowX = (($span['now'] - $span['from']) / ($span['to'] - $span['from'])) * 100;
        $html = '';
        $words = '';
        foreach ($lanes as $input) {
            $job = $input['job'];
            $parts = self::lane($input, $span, false, $job->name);
            $schedule = $job->definition->get('schedule') ?? 'no schedule';
            $html .= '<li class="lane"><div class="who"><i class="sq ' . self::STATE_CLASS[$job->health] . '" aria-hidden="true"></i><a class="name" href="' . Text::h($base) . '/jobs/'
                . Text::encodeUriComponent($job->name) . '">' . Text::name($job->name) . '</a><span class="sched">' . Text::h($schedule) . '</span></div><div class="track">'
                . $parts['svg'] . $parts['note'] . '</div></li>';
            $words .= '<li>' . Text::h("{$job->name} (" . Text::text($schedule) . "): {$parts['words']}.") . '</li>';
        }
        $count = count($lanes);
        $more = $total > $count ? "<p class=\"more\">Showing the first {$count} of {$total} jobs here; the table below lists them all.</p>" : '';
        return "<figure class=\"timeline day\">\n"
            . "<div class=\"axis\" aria-hidden=\"true\"><span></span><div class=\"hours\">{$labels}</div></div>\n"
            . "<div class=\"field\">\n"
            . "<div class=\"under\" aria-hidden=\"true\"><span></span><div>{$lines}<i class=\"future\" style=\"left:" . self::f($nowX) . "%\"></i></div></div>\n"
            . "<ol class=\"lanes\">{$html}</ol>\n"
            . "<div class=\"over\" aria-hidden=\"true\"><span></span><div><i class=\"now\" style=\"left:" . self::f($nowX) . "%\"></i></div></div>\n"
            . "</div>\n"
            . self::legend() . "{$more}\n"
            . "<ul class=\"vh\">{$words}</ul>\n"
            . '</figure>';
    }

    /**
     * A job's page: its last WEEK_DAYS UTC days, today first, one lane each.
     * `complete` is false when the runs read do not reach back over the week.
     *
     * @param list<Run> $runs
     */
    public static function weekTimeline(JobSummary $job, array $runs, bool $complete, int|float $now): string
    {
        $today = floor($now / self::DAY) * self::DAY;
        $today = Js::isInteger($today) ? (int) $today : $today;
        $oldest = $runs !== [] ? min(array_map(fn (Run $r) => $r->startedAt, $runs)) : null;
        [$lines, $labels] = self::hours(['from' => $today, 'to' => $today + self::DAY, 'now' => $now], 3 * self::HOUR, false);
        $html = '';
        $words = '';
        for ($i = 0; $i < self::WEEK_DAYS; $i++) {
            $from = $today - $i * self::DAY;
            $span = ['from' => $from, 'to' => $from + self::DAY, 'now' => $now];
            $dayRuns = array_filter($runs, fn (Run $r) => $r->startedAt < $span['to'] && ($r->finishedAt ?? $now) >= $from);
            $known = $complete || ($oldest !== null && $oldest <= $from);
            $label = $i === 0 ? 'today' : self::dayLabel($from);
            $parts = self::lane(['job' => $job, 'runs' => $runs, 'complete' => $known], $span, $i === 0, "{$job->name}, {$label}");
            $n = count($dayRuns);
            $count = "{$n} " . ($n === 1 ? 'run' : 'runs');
            $name = $i === 0 ? 'Today, ' . substr(self::dayLabel($from), 4) : self::dayLabel($from);
            $html .= '<li class="lane' . ($i === 0 ? ' today' : '') . '"><div class="who"><span class="name">' . Text::h($name) . '</span><span class="sched">' . Text::h($count)
                . '</span></div><div class="track">' . $parts['svg'] . ($i === 0 ? $parts['note'] : '') . '</div></li>';
            $words .= '<li>' . Text::h(($i === 0 ? 'Today' : self::dayLabel($from)) . ": {$parts['words']}.") . '</li>';
        }
        return "<figure class=\"timeline week\">\n"
            . "<div class=\"axis\" aria-hidden=\"true\"><span></span><div class=\"hours\">{$labels}</div></div>\n"
            . "<div class=\"field\">\n"
            . "<div class=\"under\" aria-hidden=\"true\"><span></span><div>{$lines}</div></div>\n"
            . "<ol class=\"lanes\">{$html}</ol>\n"
            . "</div>\n"
            . self::legend() . "\n"
            . "<ul class=\"vh\">{$words}</ul>\n"
            . '</figure>';
    }

    /**
     * How many runs a job's page reads so its week is drawn in full: roughly
     * how often the schedule was due over the week, with room to spare, from
     * 50 (what the run list shows) to 500 (the most runs() returns).
     */
    public static function weekRunsLimit(JobSummary $job, int|float $now): int
    {
        $parsed = self::parsedSchedule($job);
        if ($parsed === null) {
            return 50;
        }
        $from = floor($now / self::DAY) * self::DAY - (self::WEEK_DAYS - 1) * self::DAY;
        $span = $now + self::DAY - $from;
        // A cron's fires over one day, times the week: close enough, and cheap.
        if ($parsed->kind === ParsedSchedule::INTERVAL) {
            $expected = $span / $parsed->everyMs;
        } else {
            $due = self::dueTimes($job, $parsed, [], $now - self::DAY, $now);
            $expected = $due['dense'] ? INF : (count($due['times']) * $span) / self::DAY;
        }
        $wanted = $expected * 1.2;
        if (!is_finite($wanted)) {
            return 500;
        }
        return (int) min(500, max(50, ceil($wanted) + 10));
    }
}
