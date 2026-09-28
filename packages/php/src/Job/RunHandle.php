<?php

declare(strict_types=1);

namespace Cronwatch\Job;

use Cronwatch\Cronwatch;
use Cronwatch\JobDefinition;
use Cronwatch\Js;
use Cronwatch\Output;
use Cronwatch\Run;
use Cronwatch\RunStatus;

/**
 * A run recorded by $job->start() or found by $job->resume(), to finish
 * later, perhaps in another process. Lines and metrics wait in the handle
 * until flush() or finish(). Store failures go to onError; none of these
 * methods throws for them.
 *
 *     $run = $sync->start(id: $eventId);
 *     // later, perhaps elsewhere
 *     $run = $sync->resume($eventId);
 *     $run->log('sent 40 emails');
 *     $run->finish();                 // or $run->fail($error)
 */
final class RunHandle
{
    public readonly string $job;
    /** When the run started; null when a resumed run could not be read. */
    public readonly int|float|null $startedAt;
    private RunRecorder $recorder;
    private bool $finished;
    private bool $finishCalled = false;
    /**
     * The first OUTPUT_CAP characters of every line flushed from this handle,
     * unredacted, or null before the first flush. The stored output keeps
     * only the tail, so without it an expect rule at finish would miss a line
     * logged early, which run() would have seen.
     */
    private ?string $head = null;

    /** @internal Made by the client. */
    public function __construct(
        private readonly Cronwatch $client,
        /** @internal */
        public readonly JobDefinition $definition,
        public readonly string $id,
        /** @internal The run as last known here. */
        public readonly ?Run $base,
        /** @internal Whether its start is in the store. */
        public readonly bool $recorded,
        /** Why finish() has nothing to do, or null. */
        private readonly ?string $inactive,
    ) {
        $this->job = (string) $definition->get('name');
        $this->startedAt = $base?->startedAt;
        $this->recorder = $this->fresh();
        $this->finished = $inactive !== null;
    }

    private function fresh(): RunRecorder
    {
        return new RunRecorder(new Run($this->id, $this->job, RunStatus::RUNNING, $this->startedAt ?? 0), null);
    }

    /** False once finished, and from the start for a resumed run that already finished or does not exist. */
    public function isActive(): bool
    {
        return !$this->finished;
    }

    /** Add a line of output. Kept in the handle until flush() or finish(). */
    public function log(mixed ...$parts): void
    {
        $this->recorder->context->log(...$parts);
    }

    /** Report a number for this run. A later value for the same name replaces an earlier one. */
    public function metric(string $name, mixed $value): void
    {
        $this->recorder->context->metric($name, $value);
    }

    /** @param array<string, int|float> $values */
    public function metrics(array $values): void
    {
        $this->recorder->context->metrics($values);
    }

    /**
     * Append the lines and metrics added so far to the stored run, which must
     * still be running and belong to this job. A read, change and write of
     * the run's row, written only while it is still running: two processes
     * appending to one run at the same moment can lose one's lines, but a
     * flush never undoes a finish. When the write fails the lines stay here
     * for finish(). The first 16 KB of everything flushed stay in the handle,
     * so an expect rule at finish() sees an early line as run() would.
     */
    public function flush(): void
    {
        if ($this->finished || !$this->recorded) {
            return;
        }
        $lines = $this->recorder->output();
        $values = $this->recorder->metrics();
        if ($lines === null && $values === []) {
            return;
        }
        // Lines logged while this waits on the store go to a new recorder.
        $taken = $this->recorder;
        $this->recorder = $this->fresh();
        if ($this->client->flushHandle($this, $lines, $values)) {
            $this->keepHead($taken->expectText());
        } else {
            $this->putBack($taken);
        }
    }

    /**
     * Finish the run, judge it like any other and send what that produces.
     *
     *     finish()                        // ok
     *     finish(['status' => 'ok'])      // ok
     *     finish(['error' => $e])         // failed, recorded like an error run() caught
     *     finish('text')                  // like run()'s return value: the output when
     *     finish(['result' => 'text'])    // nothing was logged, checked by expect
     *
     * Returns the run as recorded, or null when nothing was: the run was
     * already finished (here or elsewhere), was not found, or belongs to
     * another job, which is reported to onError. When several processes
     * finish one run, only the one whose write lands judges it. A store that
     * fails is reported, nothing is recorded, and the handle stays active so
     * finish() can be called again.
     */
    public function finish(mixed $outcome = null): ?Run
    {
        if ($this->finishCalled) {
            $this->client->ignoreFinish($this->id, $this->job, 'was already finished by this handle');
            return null;
        }
        $wasInactive = $this->finished;
        $this->finishCalled = true;
        $this->finished = true;
        [$failed, $result, $error] = self::readOutcome($outcome);
        if ($wasInactive) {
            $this->client->ignoreFinish($this->id, $this->job, $this->inactive ?? 'was already finished');
            return null;
        }
        try {
            return $this->client->finishHandle($this, $this->recorder, $failed, $result, $error, $this->head);
        } catch (RetryFinish) {
            $this->reopen();
            return null;
        } catch (\Throwable $problem) {
            // Anything else mid-finish: the run may still be running, so the
            // handle stays open (lines kept) for finish to be called again.
            $this->reopen();
            throw $problem;
        }
    }

    /** finish(['error' => $error]). */
    public function fail(mixed $error): ?Run
    {
        return $this->finish(['error' => $error]);
    }

    /**
     * [failed, result, error] from what finish() was given. An array with an
     * "error" key (or a Throwable on its own) is a failure; a string, or an
     * array's "result", is the result.
     *
     * @return array{bool, mixed, mixed}
     */
    private static function readOutcome(mixed $outcome): array
    {
        if ($outcome instanceof \Throwable) {
            return [true, null, $outcome];
        }
        if (is_string($outcome)) {
            return [false, $outcome, null];
        }
        if (is_array($outcome)) {
            if (array_key_exists('error', $outcome)) {
                return [true, null, $outcome['error']];
            }
            return [false, $outcome['result'] ?? null, null];
        }
        return [false, null, null];
    }

    /** A flush that could not write: its lines go back ahead of any logged since. */
    private function putBack(RunRecorder $taken): void
    {
        $later = $this->recorder;
        $this->recorder = $this->fresh();
        foreach ([$taken->expectText(), $later->expectText()] as $text) {
            if ($text !== null) {
                $this->recorder->log($text);
            }
        }
        foreach (array_replace($taken->metrics(), $later->metrics()) as $name => $value) {
            $this->recorder->metric((string) $name, $value);
        }
    }

    private function reopen(): void
    {
        $this->finishCalled = false;
        $this->finished = false;
    }

    /** Keeps the start of what a flush wrote, up to the cap, for expect at finish. */
    private function keepHead(?string $text): void
    {
        if ($text === null || ($this->head !== null && Js::length16($this->head) >= Output::OUTPUT_CAP)) {
            return;
        }
        $joined = $this->head === null || $this->head === '' ? $text : "{$this->head}\n{$text}";
        $this->head = Js::head16($joined, Output::OUTPUT_CAP);
    }
}
