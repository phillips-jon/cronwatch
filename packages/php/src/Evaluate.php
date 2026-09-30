<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * Pure decisions about a job's health (evaluate.ts). Each function takes the
 * current state and returns the new state plus the alerts that should go
 * out. Nothing here touches a store or a network, which is what makes it
 * testable.
 */
final class Evaluate
{
    public const DEFAULT_GRACE_MS = 10 * 60_000;
    public const DEFAULT_TIMEOUT_MS = 60 * 60_000;
    /** Runs faster than this are never called slow, whatever the baseline says. */
    public const SLOW_FLOOR_MS = 10_000;
    /** How many earlier runs a baseline needs before it is trusted. */
    public const BASELINE_MIN_RUNS = 5;
    /** How many successful runs a baseline looks at, and how many runs a summary covers. */
    public const BASELINE_WINDOW = 20;
    /** The longest duration written: the largest integer JavaScript holds exactly, which every port and store reads back unchanged. */
    public const MAX_DURATION_MS = Js::MAX_SAFE_INTEGER;

    /**
     * How long a run took, from `startedAt` to `finishedAt` (runDuration): 0
     * when it started later, and never more than MAX_DURATION_MS. A foreign
     * row's start near a 64-bit limit must not make a duration no store can
     * write; PHP's int turns to a float past the limit, which the cap brings back.
     */
    public static function runDuration(int|float $startedAt, int|float $finishedAt): int|float
    {
        $ms = $finishedAt - $startedAt;
        if (!($ms > 0)) {
            return 0;
        }
        return $ms >= self::MAX_DURATION_MS ? self::MAX_DURATION_MS : $ms;
    }

    /**
     * When a silence of `ms` from `now` ends (silenceEnd): a whole
     * millisecond, never past MAX_DURATION_MS (2^53 - 1), however long the
     * silence asked for. Every port sharing the store reads it back
     * unchanged, where a larger number could wrap to a time long past and
     * send alerts during the silence.
     */
    public static function silenceEnd(int|float $now, int|float $ms): int|float
    {
        $whole = $ms >= self::MAX_DURATION_MS ? self::MAX_DURATION_MS : (int) floor($ms);
        $end = $now + $whole;
        return $end >= self::MAX_DURATION_MS ? self::MAX_DURATION_MS : $end;
    }

    /**
     * The version a stored state counts as for compareAndSetState
     * (stateVersion): a whole number from 0 to MAX_DURATION_MS (2^53 - 1),
     * else 0, as when it is absent. The SQL stores read it the same way, so a
     * foreign row's 1.5, "x" or -1 is written over by the next update instead
     * of refusing every compare-and-set of its job for good.
     */
    public static function stateVersion(?JobState $state): int
    {
        $version = $state?->version;
        if (is_int($version)) {
            return $version >= 0 && $version <= self::MAX_DURATION_MS ? $version : 0;
        }
        if (is_float($version) && is_finite($version) && floor($version) === $version && $version >= 0 && $version <= self::MAX_DURATION_MS) {
            return (int) $version;
        }
        return 0;
    }

    /**
     * The failures in a row a stored state counts as (failureCount): its
     * consecutiveFailures when that is a whole number, held at
     * MAX_DURATION_MS (2^53 - 1), and 0 when it is negative or not a whole
     * number. A foreign row's count at a 64-bit limit stays at the top
     * instead of turning into a float past it, and a 1.5 or -1 counts as none.
     */
    public static function failureCount(?JobState $state): int
    {
        $count = $state?->consecutiveFailures;
        if (is_int($count)) {
            return $count > 0 ? min($count, self::MAX_DURATION_MS) : 0;
        }
        if (is_float($count) && is_finite($count) && floor($count) === $count && $count > 0) {
            return $count >= self::MAX_DURATION_MS ? self::MAX_DURATION_MS : (int) $count;
        }
        return 0;
    }

    public static function emptyState(string $job): JobState
    {
        return new JobState($job, [], 0, null, null, [], []);
    }

    /** A stored state with every field present, or a fresh one. State written by an older version lacks the newer fields. */
    public static function normalizeState(?JobState $state, string $job): JobState
    {
        if ($state === null) {
            return self::emptyState($job);
        }
        return new JobState(
            $state->job,
            $state->open,
            self::failureCount($state),
            $state->silencedUntil,
            $state->lastAlertAt,
            $state->pendingRecovery ?? [],
            $state->undelivered ?? [],
            $state->version,
        );
    }

    private static function cloneState(JobState $state): JobState
    {
        return self::normalizeState($state, $state->job);
    }

    private static function openCondition(JobState $state, string $condition, int|float $now): bool
    {
        if (array_key_exists($condition, $state->open)) {
            return false;
        }
        $state->open[$condition] = $now;
        return true;
    }

    /**
     * Every open condition has alerted, so closing one owes a recovered
     * message. It is remembered until a successful run leaves nothing open
     * and sends it.
     */
    private static function closeCondition(JobState $state, string $condition): bool
    {
        if (!array_key_exists($condition, $state->open)) {
            return false;
        }
        unset($state->open[$condition]);
        $state->pendingRecovery ??= [];
        if (!in_array($condition, $state->pendingRecovery, true)) {
            $state->pendingRecovery[] = $condition;
        }
        return true;
    }

    /** @return list<string> */
    public static function openConditions(JobState $state): array
    {
        return array_map('strval', array_keys($state->open));
    }

    public static function graceMs(JobDefinition $def): int|float
    {
        return $def->get('grace') === null ? self::DEFAULT_GRACE_MS : Duration::parse($def->get('grace'), 'grace');
    }

    public static function timeoutMs(JobDefinition $def): int|float
    {
        return $def->get('timeout') === null ? self::DEFAULT_TIMEOUT_MS : Duration::parse($def->get('timeout'), 'timeout');
    }

    /**
     * Slow threshold for a successful run, or null when there is nothing to compare against yet.
     *
     * @param list<Run> $history
     * @return array{thresholdMs: int|float, basis: string}|null
     */
    public static function slowThreshold(JobDefinition $def, array $history): ?array
    {
        if ($def->get('maxDuration') !== null) {
            return ['thresholdMs' => Duration::parse($def->get('maxDuration'), 'maxDuration'), 'basis' => 'maxDuration'];
        }
        $durations = [];
        foreach ($history as $run) {
            if ($run->status === RunStatus::OK && $run->durationMs !== null) {
                $durations[] = $run->durationMs;
                if (count($durations) === self::BASELINE_WINDOW) {
                    break;
                }
            }
        }
        if (count($durations) < self::BASELINE_MIN_RUNS) {
            return null;
        }
        $p95 = Stats::percentile($durations, 95);
        return [
            'thresholdMs' => max(2 * $p95, self::SLOW_FLOOR_MS),
            'basis' => 'twice the p95 of the last ' . count($durations) . ' runs (' . Duration::format($p95) . ')',
        ];
    }

    /**
     * @param list<Run> $history
     * @return list<array{metric: string, value: int|float, limit: int|float, basis: string}>
     */
    public static function budgetBreaches(JobDefinition $def, Run $run, array $history): array
    {
        $breaches = [];
        $budget = is_array($def->get('budget')) ? $def->get('budget') : [];
        foreach (Js::objectKeys($run->metrics) as $metric) {
            $value = $run->metrics[$metric];
            if (array_key_exists($metric, $budget)) {
                $ceiling = $budget[$metric];
                if ($value > $ceiling) {
                    $breaches[] = ['metric' => $metric, 'value' => $value, 'limit' => $ceiling, 'basis' => 'budget'];
                }
                continue;
            }
            $past = [];
            foreach ($history as $r) {
                if ($r->status === RunStatus::OK && Js::isNumber($r->metrics[$metric] ?? null)) {
                    $past[] = $r->metrics[$metric];
                    if (count($past) === self::BASELINE_WINDOW) {
                        break;
                    }
                }
            }
            if (count($past) < self::BASELINE_MIN_RUNS) {
                continue;
            }
            $usual = Stats::median($past);
            if ($usual > 0 && $value > 3 * $usual) {
                $breaches[] = ['metric' => $metric, 'value' => $value, 'limit' => 3 * $usual, 'basis' => 'three times the usual ' . self::formatNumber($usual)];
            }
        }
        return $breaches;
    }

    /**
     * Whether `history` (newest first) holds a full baseline window of successful runs.
     *
     * @param list<Run> $history
     */
    public static function hasFullBaseline(array $history): bool
    {
        return count(array_filter($history, fn (Run $r) => $r->status === RunStatus::OK)) >= self::BASELINE_WINDOW;
    }

    /**
     * toLocaleString("en-US"): digit groups, and a fraction rounded half up
     * to at most four places. Worked on the shortest decimal digits, as ICU does.
     */
    public static function formatNumber(int|float $n): string
    {
        if (is_float($n) && !is_finite($n)) {
            return ($n < 0 ? '-' : '') . (is_nan($n) ? 'NaN' : "\u{221E}");
        }
        $negative = $n < 0;
        if (is_int($n)) {
            $whole = (string) abs($n);
            $fraction = '';
        } elseif ($n == 0.0) {
            $whole = '0';
            $fraction = '';
        } else {
            [$digits, $point] = Js::decimal(abs((float) $n));
            if ($point >= strlen($digits)) {
                $whole = $digits . str_repeat('0', $point - strlen($digits));
                $fraction = '';
            } elseif ($point > 0) {
                $whole = substr($digits, 0, $point);
                $fraction = substr($digits, $point);
            } else {
                $whole = '0';
                $fraction = str_repeat('0', -$point) . $digits;
            }
            if (strlen($fraction) > 4) {
                $up = (int) $fraction[4] >= 5;
                $fraction = substr($fraction, 0, 4);
                if ($up) {
                    $rounded = str_pad(self::addOne($whole . $fraction), strlen($whole) + 4, '0', STR_PAD_LEFT);
                    $whole = substr($rounded, 0, -4);
                    $fraction = substr($rounded, -4);
                }
            }
            $fraction = rtrim($fraction, '0');
        }
        $groups = [];
        while (strlen($whole) > 3) {
            array_unshift($groups, substr($whole, -3));
            $whole = substr($whole, 0, -3);
        }
        array_unshift($groups, $whole);
        $text = implode(',', $groups);
        if ($fraction !== '') {
            $text .= ".{$fraction}";
        }
        return $negative ? "-{$text}" : $text;
    }

    /** A string of decimal digits plus one, however long. */
    private static function addOne(string $digits): string
    {
        $i = strlen($digits) - 1;
        while ($i >= 0 && $digits[$i] === '9') {
            $digits[$i] = '0';
            $i--;
        }
        if ($i < 0) {
            return '1' . $digits;
        }
        $digits[$i] = (string) ((int) $digits[$i] + 1);
        return ltrim($digits, '0') === '' ? '0' : $digits;
    }

    /**
     * Called when a run starts. Missed and stuck are about the absence of a
     * run, so a run starting closes them without an alert; the recovered
     * message waits for a successful finish.
     */
    public static function onRunStart(JobState $state): JobState
    {
        $next = self::cloneState($state);
        self::closeCondition($next, Condition::MISSED);
        self::closeCondition($next, Condition::STUCK);
        return $next;
    }

    /**
     * Called when a run finishes with status ok, failed or timeout. `history`
     * is the job's earlier runs, newest first, not including this one.
     *
     * @param list<Run> $history
     */
    public static function onRunFinish(JobDefinition $def, Run $run, JobState $state, array $history, int|float $now): Evaluation
    {
        $next = self::cloneState($state);
        $alerts = [];

        if ($run->status === RunStatus::OK) {
            $next->consecutiveFailures = 0;
            self::closeCondition($next, Condition::MISSED);
            self::closeCondition($next, Condition::STUCK);
            self::closeCondition($next, Condition::FAILED);

            $slow = self::slowThreshold($def, $history);
            if ($slow !== null && $run->durationMs !== null && $run->durationMs > $slow['thresholdMs']) {
                if (self::openCondition($next, Condition::SLOW, $now)) {
                    $alerts[] = new AlertDraft(AlertType::SLOW, $run, ['durationMs' => $run->durationMs, 'thresholdMs' => $slow['thresholdMs'], 'basis' => $slow['basis']]);
                }
            } else {
                self::closeCondition($next, Condition::SLOW);
            }

            $breaches = self::budgetBreaches($def, $run, $history);
            if ($breaches !== []) {
                if (self::openCondition($next, Condition::OVER_BUDGET, $now)) {
                    $alerts[] = new AlertDraft(AlertType::OVER_BUDGET, $run, ['breaches' => $breaches]);
                }
            } else {
                self::closeCondition($next, Condition::OVER_BUDGET);
            }

            $pending = $next->pendingRecovery ?? [];
            if ($pending !== [] && self::openConditions($next) === []) {
                $alerts[] = new AlertDraft(AlertType::RECOVERED, $run, ['after' => array_values($pending)]);
                $next->pendingRecovery = [];
            }
            return new Evaluation($next, $alerts);
        }

        // failed or timeout
        // Held at the top: a count at the limit neither turns into a float nor passes 2^53 - 1.
        $next->consecutiveFailures = min(self::failureCount($next) + 1, self::MAX_DURATION_MS);
        self::closeCondition($next, Condition::MISSED);
        $threshold = max(1, $def->get('failuresBeforeAlert') ?? 1);
        $condition = $run->status === RunStatus::TIMEOUT ? Condition::STUCK : Condition::FAILED;
        if ($next->consecutiveFailures >= $threshold) {
            if (self::openCondition($next, $condition, $now)) {
                $alerts[] = new AlertDraft($condition, $run, ['consecutiveFailures' => $next->consecutiveFailures, 'threshold' => $threshold]);
            }
        }
        return new Evaluation($next, $alerts);
    }

    /**
     * Called by check(). Decides whether the schedule has been missed: the
     * run the schedule wants next (see Schedule::expectation()) has not
     * started and its grace has run out. `lastRun` is the most recent run of
     * any status. A job with no schedule is never missed, and one whose
     * schedule was removed while missed was open gets a recovered alert
     * (reason "unscheduled") for missed alone.
     */
    public static function onCheck(JobDefinition $def, StoredJob $stored, ?Run $lastRun, JobState $state, int|float $now): CheckEvaluation
    {
        $next = self::cloneState($state);
        $alerts = [];
        $schedule = $def->get('schedule');
        if ($schedule === null || $schedule === '' || $schedule === false || $schedule === 0) {
            if (array_key_exists(Condition::MISSED, $next->open)) {
                // The schedule went away while missed was open (the job was
                // declared again without one, or a source retired it), so
                // nothing is due any more. Missed closes now with a recovery of
                // its own; other open conditions keep their own rules. Missed is
                // taken out of the pending recovery too, so the next successful
                // run does not name it again.
                $since = $next->open[Condition::MISSED];
                unset($next->open[Condition::MISSED]);
                $next->pendingRecovery = array_values(array_filter($next->pendingRecovery ?? [], fn (string $c) => $c !== Condition::MISSED));
                $alerts[] = new AlertDraft(AlertType::RECOVERED, $lastRun, ['after' => [Condition::MISSED], 'reason' => 'unscheduled', 'since' => $since]);
            }
            return new CheckEvaluation($next, $alerts, null, null);
        }

        $timezone = $def->get('timezone');
        $parsed = Schedule::parse((string) $schedule, is_string($timezone) && $timezone !== '' ? $timezone : null);
        $grace = self::graceMs($def);
        $lastRunAt = $lastRun?->startedAt;
        $exp = Schedule::expectation($parsed, $lastRunAt, $stored->createdAt, $grace);
        $nextExpectedAt = $parsed->isInterval()
            ? Schedule::nextFire($parsed, $stored->createdAt, $lastRunAt)
            : Schedule::nextFire($parsed, $now, null);
        if ($exp === null) {
            return new CheckEvaluation($next, $alerts, $nextExpectedAt, null);
        }

        // An interval's next run is due a period after the last one started. If
        // that run is still going, the job is busy, not late; stuck covers one that never ends.
        if ($parsed->isInterval() && $lastRun !== null && $lastRun->status === RunStatus::RUNNING) {
            return new CheckEvaluation($next, $alerts, $nextExpectedAt, $exp->dueAt);
        }

        if ($now > $exp->deadline) {
            if (self::openCondition($next, Condition::MISSED, $now)) {
                $alerts[] = new AlertDraft(AlertType::MISSED, $lastRun, ['dueAt' => $exp->dueAt, 'deadline' => $exp->deadline, 'graceMs' => $grace, 'lastRunAt' => $lastRunAt]);
            }
        } else {
            // A run has started since it opened, or the grace was widened.
            self::closeCondition($next, Condition::MISSED);
        }
        return new CheckEvaluation($next, $alerts, $nextExpectedAt, $exp->dueAt);
    }

    /** Whether a running run has gone on longer than the job's timeout. */
    public static function isStuck(JobDefinition $def, Run $run, int|float $now): bool
    {
        return $run->status === RunStatus::RUNNING && $now - $run->startedAt > self::timeoutMs($def);
    }

    /**
     * While a job is silenced nothing new is recorded as an incident:
     * conditions may close (so a job that recovered during the silence shows
     * as healthy) but none may open, so the first problem after the silence
     * ends alerts normally.
     */
    public static function muteOpens(JobState $previous, JobState $next): JobState
    {
        $muted = self::cloneState($next);
        foreach (self::openConditions($muted) as $condition) {
            if (!array_key_exists($condition, $previous->open)) {
                unset($muted->open[$condition]);
            }
        }
        return $muted;
    }

    public static function isSilenced(JobState $state, int|float $now): bool
    {
        return $state->silencedUntil !== null && $state->silencedUntil > $now;
    }

    /** An evaluation as it is saved and sent: while the job was silenced when it began, nothing opens and nothing is sent. */
    public static function applySilence(JobState $previous, Evaluation $evaluation, int|float $now): Evaluation
    {
        if (!self::isSilenced($previous, $now)) {
            return $evaluation;
        }
        return new Evaluation(self::muteOpens($previous, $evaluation->state), []);
    }

    /**
     * Whether an alert waiting to be retried no longer describes the job, so
     * it is dropped rather than sent late. An alert for a condition is stale
     * once that condition has closed, or has closed and opened again (it
     * opened at a time other than the alert's). A recovery is stale when any
     * condition it names is open again; while they all stay closed it is kept.
     */
    public static function staleAlert(Alert $alert, JobState $state): bool
    {
        if ($alert->type === AlertType::RECOVERED) {
            foreach ($alert->details['after'] ?? [] as $condition) {
                if (array_key_exists((string) $condition, $state->open)) {
                    return true;
                }
            }
            return false;
        }
        return !array_key_exists($alert->type, $state->open) || $state->open[$alert->type] != $alert->at;
    }

    /** How a job looks at a glance. Silence wins, then stuck, failing and late. */
    public static function jobHealth(JobDefinition $def, ?Run $lastRun, JobState $state, int|float $now): string
    {
        $open = self::openConditions($state);
        if (self::isSilenced($state, $now)) {
            return JobHealth::SILENCED;
        }
        if (in_array(Condition::STUCK, $open, true) || ($lastRun !== null && self::isStuck($def, $lastRun, $now))) {
            return JobHealth::STUCK;
        }
        if (in_array(Condition::FAILED, $open, true) || ($lastRun !== null && in_array($lastRun->status, [RunStatus::FAILED, RunStatus::TIMEOUT], true))) {
            return JobHealth::FAILING;
        }
        if (in_array(Condition::MISSED, $open, true)) {
            return JobHealth::LATE;
        }
        if ($lastRun === null) {
            return JobHealth::NEVER_RAN;
        }
        return JobHealth::HEALTHY;
    }

    /**
     * A job's summary from its most recent runs (newest first; the first
     * BASELINE_WINDOW are used) and its state. Stats cover runs of any
     * status; the percentiles are over the successful ones among them.
     *
     * @param list<Run> $recent
     */
    public static function summarize(StoredJob $stored, array $recent, JobState $state, int|float|null $nextExpectedAt, int|float $now): JobSummary
    {
        return self::summary($stored, $recent, $state, $nextExpectedAt, fn (?Run $lastRun) => self::jobHealth($stored->definition, $lastRun, $state, $now));
    }

    /**
     * The summary of a job that could not be evaluated, say because its
     * stored schedule no longer parses. It reads nothing from the
     * definition. The job shows as failing (or silenced, while it is), since
     * it needs a look, and nothing is known about when it is next due.
     *
     * @param list<Run> $recent
     */
    public static function unevaluableSummary(StoredJob $stored, array $recent, JobState $state, int|float $now): JobSummary
    {
        return self::summary($stored, $recent, $state, null, fn () => self::isSilenced($state, $now) ? JobHealth::SILENCED : JobHealth::FAILING);
    }

    /**
     * @param list<Run> $recent
     * @param \Closure(?Run): string $health
     */
    private static function summary(StoredJob $stored, array $recent, JobState $state, int|float|null $nextExpectedAt, \Closure $health): JobSummary
    {
        $window = array_slice($recent, 0, self::BASELINE_WINDOW);
        $lastRun = $window[0] ?? null;
        $finished = array_values(array_filter($window, fn (Run $r) => $r->status !== RunStatus::RUNNING));
        $okDurations = [];
        foreach ($window as $r) {
            if ($r->status === RunStatus::OK && $r->durationMs !== null) {
                $okDurations[] = $r->durationMs;
            }
        }
        $ok = count(array_filter($finished, fn (Run $r) => $r->status === RunStatus::OK));
        return new JobSummary(
            name: $stored->name,
            definition: $stored->definition,
            health: $health($lastRun),
            open: self::openConditions($state),
            lastRun: $lastRun,
            nextExpectedAt: $nextExpectedAt,
            consecutiveFailures: $state->consecutiveFailures,
            silencedUntil: $state->silencedUntil,
            stats: [
                'runs' => count($finished),
                'okRate' => $finished === [] ? 1 : $ok / count($finished),
                'p50Ms' => Stats::percentile($okDurations, 50),
                'p95Ms' => Stats::percentile($okDurations, 95),
            ],
        );
    }
}
