<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Alert;
use Cronwatch\AlertDraft;
use Cronwatch\Duration;
use Cronwatch\Evaluate;
use Cronwatch\Evaluation;
use Cronwatch\Format;
use Cronwatch\Job\RunRecorder;
use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Js;
use Cronwatch\Output;
use Cronwatch\Pattern;
use Cronwatch\Run;
use Cronwatch\RunStatus;
use Cronwatch\Schedule;
use Cronwatch\Serialize;
use Cronwatch\Stats;
use Cronwatch\StoredJob;
use Cronwatch\Tests\Support\Backend;
use Cronwatch\Tests\Support\Clock;
use Cronwatch\Tests\Support\Sim;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * Replays the cases in conformance/ (written by scripts/conformance.mjs from
 * the TypeScript SDK) that the core covers: durations, schedules, the alert
 * rules, titles and messages, health and stats, output and redaction, and
 * the store scripts against every store. Values are compared as the JSON the
 * SDK would write, so key order and number formatting count too. The
 * channel, pg_cron and triage fixtures are replayed by tests of their own
 * (ChannelConformanceTest, PgCronTest, TriageTest), listed here so a new
 * fixture fails until something replays it.
 */
final class ConformanceTest extends TestCase
{
    private const DIR = __DIR__ . '/../../../conformance';

    /** @var array<string, \stdClass> */
    private static array $fixtures = [];

    private static function fixture(string $name): \stdClass
    {
        return self::$fixtures[$name] ??= Js::parse((string) file_get_contents(self::DIR . "/{$name}"));
    }

    /** JSON has no NaN or Infinity; the fixtures write them as {"special": "NaN"}. */
    private static function decode(mixed $value): mixed
    {
        if ($value instanceof \stdClass && isset($value->special)) {
            return ['NaN' => NAN, 'Infinity' => INF, '-Infinity' => -INF][$value->special];
        }
        return $value;
    }

    /**
     * Runs each case, collecting mismatches, so one failure lists them all.
     *
     * @param list<\stdClass> $cases
     * @param \Closure(\stdClass): ?string $check
     */
    private function eachCase(array $cases, \Closure $check): void
    {
        $failures = [];
        foreach ($cases as $i => $case) {
            try {
                $message = $check($case);
            } catch (\Throwable $error) {
                $message = 'threw ' . get_class($error) . ': ' . $error->getMessage();
            }
            if ($message !== null) {
                $failures[] = "#{$i} " . substr(Js::stringify($case), 0, 300) . "\n    {$message}";
            }
        }
        $this->assertSame([], $failures, count($failures) . ' of ' . count($cases) . " cases differ:\n" . implode("\n", array_slice($failures, 0, 15)));
    }

    private static function differs(mixed $expected, mixed $actual): ?string
    {
        $e = is_string($expected) ? $expected : Js::stringify($expected);
        $a = is_string($actual) ? $actual : Js::stringify($actual);
        return $e === $a ? null : 'expected ' . substr($e, 0, 1500) . "\n    got      " . substr($a, 0, 1500);
    }

    private static function throws(string $expected, \Closure $fn): ?string
    {
        try {
            $fn();
        } catch (\InvalidArgumentException $error) {
            return $error->getMessage() === $expected ? null : "expected error {$expected}\n    got   error {$error->getMessage()}";
        }
        return "expected an error: {$expected}";
    }

    // ------------------------------------------------------------ duration

    public function testDurationParse(): void
    {
        $this->eachCase(self::fixture('duration.json')->parse, function (\stdClass $c): ?string {
            $args = [self::decode($c->input), $c->label ?? 'duration'];
            if (isset($c->error)) {
                return self::throws($c->error, fn () => Duration::parse(...$args));
            }
            return self::differs($c->ms, Duration::parse(...$args));
        });
    }

    public function testDurationFormat(): void
    {
        $this->eachCase(self::fixture('duration.json')->format, fn (\stdClass $c) => self::differs($c->text, Duration::format(self::decode($c->ms))));
    }

    public function testDurationRelative(): void
    {
        $this->eachCase(self::fixture('duration.json')->relative, fn (\stdClass $c) => self::differs($c->text, Duration::relative($c->at, $c->now)));
    }

    // ------------------------------------------------------------ schedule

    public function testScheduleParse(): void
    {
        $this->eachCase(self::fixture('schedule.json')->parse, function (\stdClass $c): ?string {
            if (isset($c->error)) {
                return self::throws($c->error, fn () => Schedule::parse($c->schedule, $c->timezone ?? null));
            }
            return self::differs($c->parsed, Schedule::parse($c->schedule, $c->timezone ?? null));
        });
    }

    /** @param list<int|float|null> $values */
    private static function times(array $values): array
    {
        return array_map(fn ($v) => $v === null ? null : Js::iso($v), $values);
    }

    public function testScheduleFires(): void
    {
        $this->eachCase(self::fixture('schedule.json')->fires, function (\stdClass $c): ?string {
            $parsed = Schedule::parse($c->schedule, $c->timezone ?? null);
            $t = $c->from;
            $fires = [];
            foreach ($c->fires as $_) {
                $t = Schedule::nextFire($parsed, $t, null);
                $fires[] = $t;
                if ($t === null) {
                    break;
                }
            }
            return self::differs(self::times($c->fires), self::times($fires));
        });
    }

    public function testScheduleNextFireAcrossTheAutumnClockChange(): void
    {
        $this->eachCase(self::fixture('schedule.json')->autumn, function (\stdClass $c): ?string {
            $parsed = Schedule::parse($c->schedule, $c->timezone ?? null);
            $actual = [];
            foreach (array_keys($c->next) as $i) {
                $actual[] = Schedule::nextFire($parsed, $c->from + $i * $c->stepMs, null);
            }
            return self::differs(self::times($c->next), self::times($actual));
        });
    }

    public function testScheduleNextFireForIntervals(): void
    {
        $this->eachCase(self::fixture('schedule.json')->nextFire, fn (\stdClass $c) => self::differs($c->expected, Schedule::nextFire(Schedule::parse($c->schedule), $c->from, $c->lastRunAt)));
    }

    public function testScheduleExpectation(): void
    {
        $this->eachCase(self::fixture('schedule.json')->expectation, function (\stdClass $c): ?string {
            $parsed = Schedule::parse($c->schedule, $c->timezone ?? null);
            return self::differs($c->expected, Schedule::expectation($parsed, $c->lastRunAt, $c->registeredAt, $c->graceMs));
        });
    }

    public function testScheduleRunCovers(): void
    {
        $this->eachCase(self::fixture('schedule.json')->runCovers, fn (\stdClass $c) => self::differs($c->expected, Schedule::runCovers($c->startedAt, $c->dueAt, $c->followingAt)));
    }

    // ------------------------------------------------------------ evaluate

    public static function scenarios(): iterable
    {
        foreach (self::fixture('evaluate.json')->scenarios as $scenario) {
            yield $scenario->name => [$scenario];
        }
    }

    #[DataProvider('scenarios')]
    public function testScenario(\stdClass $scenario): void
    {
        $sim = new Sim(JobDefinition::fromJson($scenario->definition), $scenario->createdAt);
        foreach ($scenario->events as $i => $event) {
            $actual = match ($event->op) {
                'start' => $sim->start($event->id, $event->at),
                'finish' => $sim->finish($event->id, $event->at, $event),
                'check' => $sim->check($event->at),
                'silence' => $sim->silence($event->until),
                'unsilence' => $sim->silence(null),
                'define' => null,
                default => throw new \LogicException("unknown event {$event->op}"),
            };
            if ($event->op === 'define') {
                $sim->define(JobDefinition::fromJson($event->definition));
                continue;
            }
            foreach (get_object_vars($event->expect) as $key => $expected) {
                $this->assertNull(self::differs($expected, $actual[$key] ?? null), "{$scenario->name}: event {$i} ({$event->op} at " . ($event->at ?? '') . "), {$key}");
            }
        }
    }

    // ------------------------------------------------------------ format

    private static function draftFrom(\stdClass $data): AlertDraft
    {
        return new AlertDraft($data->type, $data->run === null ? null : Run::fromJson($data->run), Js::plain($data->details));
    }

    public function testComposeAlert(): void
    {
        $this->eachCase(self::fixture('format.json')->alerts, fn (\stdClass $c) => self::differs(
            $c->alert,
            Format::composeAlert(self::draftFrom($c->draft), JobDefinition::fromJson($c->definition), $c->now),
        ));
    }

    public function testFormatNumber(): void
    {
        $this->eachCase(self::fixture('format.json')->numbers, fn (\stdClass $c) => self::differs($c->text, Evaluate::formatNumber($c->n)));
    }

    public function testCapOutput(): void
    {
        $this->eachCase(self::fixture('format.json')->capOutput, function (\stdClass $c): ?string {
            $capped = Output::capOutput($c->prefix . str_repeat($c->piece, $c->times));
            return self::differs([$c->length, $c->sha256], [Js::length16($capped), hash('sha256', $capped)]);
        });
    }

    private static function expectFrom(mixed $value): mixed
    {
        if (!$value instanceof \stdClass) {
            return $value;
        }
        if (isset($value->callable)) {
            return fn (string $text) => Js::length16($text) > 3;
        }
        return Pattern::fromJs($value->regex->source, $value->regex->flags);
    }

    public function testToStored(): void
    {
        $this->eachCase(self::fixture('format.json')->toStored, function (\stdClass $c): ?string {
            $fields = [];
            foreach (get_object_vars($c->definition) as $key => $value) {
                $fields[$key] = $key === 'expect' ? self::expectFrom($value) : ($key === 'budget' ? Js::fields($value) : $value);
            }
            return self::differs($c->stored, Serialize::toStored(new JobDefinition($fields)));
        });
    }

    public function testCheckExpectation(): void
    {
        $this->eachCase(self::fixture('format.json')->checkExpectation, fn (\stdClass $c) => self::differs($c->result, Serialize::checkExpectation(self::expectFrom($c->expect), $c->output)));
    }

    // ------------------------------------------------------------ health

    private static function state(?\stdClass $data): ?JobState
    {
        return $data === null ? null : JobState::fromJson($data);
    }

    private static function runFrom(?\stdClass $data): ?Run
    {
        return $data === null ? null : Run::fromJson($data);
    }

    /** @return list<Run> */
    private static function recent(array $runs): array
    {
        return array_map(fn (\stdClass $r) => Run::fromJson($r), $runs);
    }

    public function testJobHealth(): void
    {
        $this->eachCase(self::fixture('health.json')->jobHealth, fn (\stdClass $c) => self::differs(
            $c->health,
            Evaluate::jobHealth(JobDefinition::fromJson($c->definition), self::runFrom($c->lastRun), self::state($c->state), $c->now),
        ));
    }

    public function testSummarize(): void
    {
        $this->eachCase(self::fixture('health.json')->summarize, fn (\stdClass $c) => self::differs(
            $c->summary,
            Evaluate::summarize(StoredJob::fromJson($c->stored), self::recent($c->recent), self::state($c->state), $c->nextExpectedAt, $c->now),
        ));
    }

    public function testPercentileAndMedian(): void
    {
        $this->eachCase(self::fixture('health.json')->percentile, fn (\stdClass $c) => self::differs($c->percentile, Stats::percentile($c->values, $c->p)));
        $this->eachCase(self::fixture('health.json')->median, fn (\stdClass $c) => self::differs($c->median, Stats::median($c->values)));
    }

    public function testNormalizeState(): void
    {
        $this->eachCase(self::fixture('health.json')->normalizeState, fn (\stdClass $c) => self::differs($c->normalized, Evaluate::normalizeState(self::state($c->state), 'j')));
    }

    public function testMuteOpens(): void
    {
        $this->eachCase(self::fixture('health.json')->muteOpens, fn (\stdClass $c) => self::differs($c->muted, Evaluate::muteOpens(self::state($c->previous), self::state($c->next))));
    }

    public function testIsStuck(): void
    {
        $this->eachCase(self::fixture('health.json')->isStuck, fn (\stdClass $c) => self::differs($c->stuck, Evaluate::isStuck(JobDefinition::fromJson($c->definition), Run::fromJson($c->run), $c->now)));
    }

    public function testRunDuration(): void
    {
        $this->eachCase(self::fixture('health.json')->runDuration, fn (\stdClass $c) => self::differs($c->durationMs, Evaluate::runDuration($c->startedAt, $c->finishedAt)));
    }

    public function testStateVersion(): void
    {
        $this->eachCase(self::fixture('health.json')->stateVersion, fn (\stdClass $c) => self::differs($c->version, Evaluate::stateVersion(JobState::fromJson(Js::parse($c->state)))));
    }

    public function testFailureCount(): void
    {
        $def = JobDefinition::fromJson(['name' => 'j', 'failuresBeforeAlert' => 3]);
        $run = Run::fromJson([
            'id' => 'f', 'job' => 'j', 'status' => 'failed', 'startedAt' => Clock::T0 - 60_000, 'finishedAt' => Clock::T0 - 59_000, 'durationMs' => 1000,
            'error' => 'Error: boom', 'output' => null, 'metrics' => new \stdClass(), 'trigger' => 'run',
        ]);
        $this->eachCase(self::fixture('health.json')->failureCount, function (\stdClass $c) use ($def, $run): ?string {
            $normalized = Evaluate::normalizeState(JobState::fromJson(Js::parse($c->state)), 'j');
            $failed = Evaluate::onRunFinish($def, $run, $normalized, [], Clock::T0);
            return self::differs($c->consecutiveFailures, $normalized->consecutiveFailures)
                ?? self::differs($c->failed, ['state' => $failed->state, 'alerts' => $failed->alerts]);
        });
    }

    public function testUnevaluableSummary(): void
    {
        $this->eachCase(self::fixture('health.json')->unevaluableSummary, fn (\stdClass $c) => self::differs(
            $c->summary,
            Evaluate::unevaluableSummary(StoredJob::fromJson($c->stored), self::recent($c->recent), self::state($c->state), $c->now),
        ));
    }

    public function testApplySilence(): void
    {
        $this->eachCase(self::fixture('health.json')->applySilence, function (\stdClass $c): ?string {
            $evaluation = new Evaluation(self::state($c->evaluation->state), array_map(self::draftFrom(...), $c->evaluation->alerts));
            $result = Evaluate::applySilence(self::state($c->previous), $evaluation, $c->now);
            return self::differs($c->result, ['state' => $result->state, 'alerts' => $result->alerts]);
        });
    }

    public function testSilenceEnd(): void
    {
        $this->eachCase(self::fixture('health.json')->silenceEnd, fn (\stdClass $c) => self::differs(
            $c->silencedUntil,
            Evaluate::silenceEnd($c->now, Duration::parse($c->duration, 'silence duration')),
        ));
    }

    public function testStaleAlert(): void
    {
        $this->eachCase(self::fixture('health.json')->staleAlert, fn (\stdClass $c) => self::differs($c->stale, Evaluate::staleAlert(Alert::fromJson($c->alert), self::state($c->state))));
    }

    // ------------------------------------------------------------ output

    /** Long text travels as {"parts": [[piece, times], ...]}. */
    private static function expand(mixed $spec): mixed
    {
        if ($spec instanceof \stdClass && isset($spec->parts)) {
            return implode('', array_map(fn (array $part) => str_repeat($part[0], $part[1]), $spec->parts));
        }
        return $spec;
    }

    /** A result as the fixtures hold it: the text, or when long its length in UTF-16 code units and SHA-256. */
    private static function digest(?string $text): ?array
    {
        if ($text === null) {
            return null;
        }
        $length = Js::length16($text);
        return $length <= 400 ? ['text' => $text] : ['length' => $length, 'sha256' => hash('sha256', $text)];
    }

    public function testOutputCapIsTheSdks(): void
    {
        $this->assertSame(self::fixture('output.json')->outputCap, Output::OUTPUT_CAP);
    }

    public function testRedactSecrets(): void
    {
        $this->eachCase(self::fixture('output.json')->redact, fn (\stdClass $c) => self::differs($c->result, self::digest(Output::redactSecrets(self::expand($c->input)))));
    }

    public function testRedactAndCap(): void
    {
        $this->assertSame(self::fixture('output.json')->redactEdge, Output::REDACT_EDGE);
        $redact = Output::redactSecrets(...);
        $this->eachCase(self::fixture('output.json')->redactAndCap, fn (\stdClass $c) => self::differs($c->result, self::digest(Output::redactAndCap(self::expand($c->input), $redact))));
    }

    /** An error message from a name, a message and frames, as a Throwable's is written, or from a value that is not one. */
    public function testErrorMessage(): void
    {
        $this->eachCase(self::fixture('output.json')->errorMessage, function (\stdClass $c): ?string {
            if (property_exists($c, 'value')) {
                return self::differs($c->result, self::digest(Output::errorMessage(Js::plain(self::expand($c->value)))));
            }
            $text = Output::capOutput(Output::describe($c->name, self::expand($c->message), $c->frames));
            return self::differs($c->result, self::digest($text));
        });
    }

    /** @return list<string> */
    private static function expandLines(array $lines): array
    {
        $out = [];
        foreach ($lines as $line) {
            if ($line instanceof \stdClass && isset($line->numbered)) {
                for ($i = 0; $i < $line->count; $i++) {
                    $head = "{$line->numbered}{$i} ";
                    $out[] = $head . str_repeat('x', max(0, $line->width - Js::length16($head)));
                }
            } else {
                $out[] = self::expand($line);
            }
        }
        return $out;
    }

    public function testExpectText(): void
    {
        $this->eachCase(self::fixture('output.json')->expectText, function (\stdClass $c): ?string {
            $recorder = new RunRecorder(new Run('r', 'j', RunStatus::RUNNING, Clock::T0), 60_000);
            foreach (self::expandLines($c->lines) as $line) {
                $recorder->context->log($line);
            }
            $text = $recorder->expectText();
            $checks = array_map(fn (\stdClass $k) => ['expect' => $k->expect, 'result' => Serialize::checkExpectation($k->expect, $text)], $c->checks);
            return self::differs([$c->expectText, $c->output, $c->checks], [self::digest($text), self::digest($recorder->output()), $checks]);
        });
    }

    // ------------------------------------------------------------ store

    public static function stores(): iterable
    {
        foreach (['memory', 'sqlite', 'mysql', 'mariadb', 'postgres'] as $kind) {
            yield $kind => [$kind];
        }
    }

    private function backend(string $kind): Backend
    {
        $why = Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        return Backend::make($kind);
    }

    #[DataProvider('stores')]
    public function testStorePrune(string $kind): void
    {
        $this->backend($kind)->done();
        $this->eachCase(self::fixture('store.json')->prune, function (\stdClass $c) use ($kind): ?string {
            $backend = Backend::make($kind);
            try {
                $store = $backend->open();
                $store->init();
                $mismatch = null;
                foreach ($c->events as $event) {
                    if (isset($event->insert)) {
                        foreach ($event->insert as $run) {
                            $store->insertRun(Run::fromJson($run));
                        }
                        continue;
                    }
                    $pruned = $store->prune($event->prune);
                    $remaining = [];
                    foreach (array_keys(get_object_vars($event->remaining)) as $job) {
                        $remaining[$job] = array_map(fn (Run $r) => $r->id, $store->listRuns((string) $job, 100));
                    }
                    $mismatch ??= self::differs([$event->pruned, $event->remaining], [$pruned, Js::obj($remaining)]);
                }
                return $mismatch;
            } finally {
                $backend->done();
            }
        });
    }

    #[DataProvider('stores')]
    public function testStoreCompareAndSetState(string $kind): void
    {
        $backend = $this->backend($kind);
        try {
            $store = $backend->open();
            $store->init();
            $this->eachCase(self::fixture('store.json')->compareAndSetState, function (\stdClass $c) use ($store): ?string {
                $written = null;
                if (isset($c->cas)) {
                    $written = $store->compareAndSetState(JobState::fromJson($c->cas), $c->expected);
                } elseif (isset($c->set)) {
                    $store->setState(JobState::fromJson($c->set));
                } else {
                    $store->deleteJob($c->forget);
                }
                $states = [];
                foreach (['a', 'b'] as $job) {
                    $states[$job] = $store->getState($job);
                }
                $actual = property_exists($c, 'written') ? ['written' => $written, 'states' => $states] : ['states' => $states];
                $expected = property_exists($c, 'written') ? ['written' => $c->written, 'states' => $c->states] : ['states' => $c->states];
                return self::differs($expected, $actual);
            });
        } finally {
            $backend->done();
        }
    }

    #[DataProvider('stores')]
    public function testStoreUpdateRunIf(string $kind): void
    {
        $backend = $this->backend($kind);
        try {
            $store = $backend->open();
            $store->init();
            $store->insertRun(new Run('u1', 'a', RunStatus::RUNNING, 1000));
            $this->eachCase(self::fixture('store.json')->updateRunIf, function (\stdClass $c) use ($store): ?string {
                $outcome = null;
                if (isset($c->set)) {
                    $store->updateRun(Run::fromJson($c->set));
                } elseif (isset($c->insert)) {
                    try {
                        $store->insertRun(Run::fromJson($c->insert));
                        $outcome = 'inserted';
                    } catch (\Throwable) {
                        $outcome = 'refused';
                    }
                } else {
                    $outcome = $store->updateRunIf(Run::fromJson($c->run), $c->from);
                }
                return self::differs([$c->outcome ?? null, $c->stored], [$outcome, $store->getRun('u1')]);
            });
        } finally {
            $backend->done();
        }
    }

    /**
     * A state row another process wrote, its version in any shape: held as
     * its JSON text as it is (on the memory store, as the SDK's reader reads
     * it), it counts as Evaluate::stateVersion() says.
     */
    #[DataProvider('stores')]
    public function testStoreForeignVersion(string $kind): void
    {
        $backend = $this->backend($kind);
        try {
            $store = $backend->open();
            $store->init();
            $pdo = $kind === 'memory' ? null : $backend->pdo();
            $insert = match ($kind) {
                'memory' => null,
                'postgres' => "INSERT INTO {$backend->tables()}state (job, state) VALUES ('v', CAST(? AS jsonb))",
                default => "INSERT INTO {$backend->tables()}state (job, state) VALUES ('v', ?)",
            };
            $this->eachCase(self::fixture('store.json')->foreignVersion, function (\stdClass $c) use ($store, $pdo, $insert): ?string {
                $store->deleteJob('v');
                if ($pdo === null) {
                    $store->setState(JobState::fromJson(Js::parse($c->stored)));
                } else {
                    $pdo->prepare((string) $insert)->execute([$c->stored]);
                }
                foreach ($c->steps as $i => $step) {
                    $written = $store->compareAndSetState(JobState::fromJson($step->cas), $step->expected);
                    $mismatch = self::differs(
                        property_exists($step, 'state') ? [$step->written, $step->state] : [$step->written],
                        property_exists($step, 'state') ? [$written, $store->getState('v')] : [$written],
                    );
                    if ($mismatch !== null) {
                        return "step {$i}: {$mismatch}";
                    }
                }
                return null;
            });
        } finally {
            $backend->done();
        }
    }

    /**
     * Text is written without U+0000, which Postgres refuses: a run's
     * trigger, output, error and metric names, and every key and string of
     * a definition and a state. The six characters "\u0000" stay.
     */
    #[DataProvider('stores')]
    public function testStoreNul(string $kind): void
    {
        $backend = $this->backend($kind);
        try {
            $store = $backend->open();
            $store->init();
            $this->eachCase(self::fixture('store.json')->nul, function (\stdClass $c) use ($store): ?string {
                $written = null;
                if (isset($c->upsertJob)) {
                    $store->upsertJob(JobDefinition::fromJson($c->upsertJob), $c->now);
                    $stored = $store->getJob('nul');
                } elseif (isset($c->insertRun)) {
                    $store->insertRun(Run::fromJson($c->insertRun));
                    $stored = $store->getRun('n1');
                } elseif (isset($c->updateRun)) {
                    $store->updateRun(Run::fromJson($c->updateRun));
                    $stored = $store->getRun('n1');
                } elseif (isset($c->updateRunIf)) {
                    $written = $store->updateRunIf(Run::fromJson($c->updateRunIf), $c->from);
                    $stored = $store->getRun('n1');
                } elseif (isset($c->setState)) {
                    $store->setState(JobState::fromJson($c->setState));
                    $stored = $store->getState('nul');
                } else {
                    $written = $store->compareAndSetState(JobState::fromJson($c->compareAndSetState), $c->expected);
                    $stored = $store->getState('nul');
                }
                // Postgres's JSONB holds keys in an order of its own.
                $sorted = function (mixed $value) use (&$sorted): mixed {
                    if (!is_array($value)) {
                        return $value;
                    }
                    if (!array_is_list($value)) {
                        ksort($value, SORT_STRING);
                    }
                    return array_map($sorted, $value);
                };
                $canonical = fn (mixed $value) => Js::stringify($sorted(json_decode(Js::stringify($value), true)));
                return self::differs($canonical([$c->written ?? null, $c->stored]), $canonical([$written, $stored]));
            });
        } finally {
            $backend->done();
        }
    }

    // ------------------------------------------------------------ every fixture

    /** The fixtures replayed by a test of their own. */
    private const ELSEWHERE = [
        'channels.json' => ChannelConformanceTest::class,
        'pgcron.json' => PgCronTest::class,
        'triage.json' => TriageTest::class,
    ];

    public function testEveryFixtureIsReplayed(): void
    {
        $replayed = ['duration.json', 'schedule.json', 'evaluate.json', 'format.json', 'health.json', 'output.json', 'store.json'];
        foreach (self::ELSEWHERE as $test) {
            $this->assertTrue(class_exists($test), "{$test} replays a fixture");
        }
        $all = array_map('basename', glob(self::DIR . '/*.json') ?: []);
        sort($all);
        $known = [...$replayed, ...array_keys(self::ELSEWHERE)];
        sort($known);
        $this->assertSame($known, $all);
    }
}
