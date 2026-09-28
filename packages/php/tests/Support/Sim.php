<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Support;

use Cronwatch\Alert;
use Cronwatch\Duration;
use Cronwatch\Evaluate;
use Cronwatch\Evaluation;
use Cronwatch\Format;
use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Js;
use Cronwatch\Run;
use Cronwatch\RunStatus;
use Cronwatch\StoredJob;

/**
 * The conformance generator's Sim: a job's life through the pure functions,
 * the way the client plays it, for conformance/evaluate.json.
 */
final class Sim
{
    public StoredJob $stored;
    public JobState $state;
    /** @var list<Run> */
    public array $runs = [];
    /** @var array<string, int> */
    private array $order = [];
    private int $seq = 0;

    public function __construct(public JobDefinition $definition, int|float $createdAt)
    {
        $this->stored = new StoredJob((string) $definition->get('name'), $definition, $createdAt, $createdAt);
        $this->state = Evaluate::emptyState((string) $definition->get('name'));
    }

    public function define(JobDefinition $definition): void
    {
        $this->definition = $definition;
        $this->stored = new StoredJob($this->stored->name, $definition, $this->stored->createdAt, $this->stored->updatedAt);
    }

    public function silence(int|float|null $until): array
    {
        $this->state = clone $this->state;
        $this->state->silencedUntil = $until;
        return ['state' => $this->state];
    }

    /** @return list<Run> newest first */
    private function sorted(): array
    {
        $runs = $this->runs;
        usort($runs, fn (Run $a, Run $b) => [$b->startedAt, $this->order[$b->id]] <=> [$a->startedAt, $this->order[$a->id]]);
        return $runs;
    }

    /** @return list<Alert> */
    private function settle(JobState $previous, Evaluation $evaluation, int|float $now): array
    {
        $state = $evaluation->state;
        $alerts = $evaluation->alerts;
        if (Evaluate::isSilenced($previous, $now)) {
            $state = Evaluate::muteOpens($previous, $state);
            $alerts = [];
        }
        $this->state = $state;
        return array_map(fn ($draft) => Format::composeAlert($draft, $this->definition, $now), $alerts);
    }

    public function start(string $id, int|float $now): array
    {
        $this->runs[] = new Run($id, (string) $this->definition->get('name'), RunStatus::RUNNING, $now);
        $this->order[$id] = ++$this->seq;
        $this->state = Evaluate::onRunStart($this->state);
        return ['state' => $this->state];
    }

    /** @return list<Alert> */
    private function finishRun(Run $run, int|float $now): array
    {
        $history = array_map(fn (Run $r) => clone $r, array_values(array_filter($this->sorted(), fn (Run $r) => $r->id !== $run->id)));
        $previous = $this->state;
        return $this->settle($previous, Evaluate::onRunFinish($this->definition, clone $run, $previous, $history, $now), $now);
    }

    public function finish(string $id, int|float $now, \stdClass $fields): array
    {
        $run = null;
        foreach ($this->runs as $candidate) {
            if ($candidate->id === $id) {
                $run = $candidate;
            }
        }
        // As the client's conditional write (updateRunIf): a run already
        // finished takes no second finish, and nothing is judged.
        if (in_array($run->status, [RunStatus::OK, RunStatus::FAILED], true)) {
            return ['alerts' => [], 'state' => $this->state, 'ignored' => "was already finished as {$run->status}"];
        }
        $markedTimedOut = $run->status === RunStatus::TIMEOUT;
        $run->finishedAt = $now;
        $run->durationMs = max(0, $now - $run->startedAt);
        $run->status = $fields->status;
        $run->metrics = Js::fields($fields->metrics ?? []);
        $run->output = $fields->output ?? null;
        $run->error = $fields->error ?? null;
        // As the client does: a check already counted this run as stuck, so a
        // late failure only updates the run; a late success is evaluated.
        if ($markedTimedOut && $run->status !== RunStatus::OK) {
            return ['alerts' => [], 'state' => $this->state];
        }
        return ['alerts' => $this->finishRun($run, $now), 'state' => $this->state];
    }

    public function check(int|float $now): array
    {
        $alerts = [];
        $running = array_values(array_filter($this->runs, fn (Run $r) => $r->status === RunStatus::RUNNING));
        usort($running, fn (Run $a, Run $b) => [$a->startedAt, $this->order[$a->id]] <=> [$b->startedAt, $this->order[$b->id]]);
        foreach ($running as $run) {
            if (!Evaluate::isStuck($this->definition, $run, $now)) {
                continue;
            }
            $run->status = RunStatus::TIMEOUT;
            $run->finishedAt = $now;
            $run->durationMs = $now - $run->startedAt;
            $run->error = 'Still running after ' . Duration::format(Evaluate::timeoutMs($this->definition)) . '; marked as timed out';
            array_push($alerts, ...$this->finishRun($run, $now));
        }
        $recent = array_map(fn (Run $r) => clone $r, array_slice($this->sorted(), 0, 20));
        $previous = $this->state;
        $evaluation = Evaluate::onCheck($this->definition, $this->stored, $recent[0] ?? null, $previous, $now);
        array_push($alerts, ...$this->settle($previous, $evaluation, $now));
        return [
            'alerts' => $alerts,
            'state' => $this->state,
            'nextExpectedAt' => $evaluation->nextExpectedAt,
            'dueAt' => $evaluation->dueAt,
            'summary' => Evaluate::summarize($this->stored, $recent, $this->state, $evaluation->nextExpectedAt, $now),
        ];
    }
}
