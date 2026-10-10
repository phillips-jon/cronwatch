<?php

declare(strict_types=1);

namespace Cronwatch\Job;

use Cronwatch\Js;
use Cronwatch\Output;
use Cronwatch\Run;

/**
 * What a job receives: its name, run id, and start, a signal that aborts at
 * the job's timeout, and log() and metric().
 */
final class JobContext
{
    public readonly string $name;
    public readonly string $runId;
    public readonly int|float $startedAt;

    /** @internal */
    public function __construct(Run $run, public readonly AbortSignal $signal, private readonly RunRecorder $recorder)
    {
        $this->name = $run->job;
        $this->runId = $run->id;
        $this->startedAt = $run->startedAt;
    }

    /** Append a line of output. Kept with the run, capped at 16 KB, shown in alerts and the dashboard. */
    public function log(mixed ...$parts): void
    {
        $this->recorder->log(implode(' ', array_map(self::stringify(...), $parts)));
    }

    /** Report a number for this run: tokens, cost, rows, anything. Watched against budgets and baselines. */
    public function metric(string $name, mixed $value): void
    {
        if (!Js::isFinite($value)) {
            throw new \InvalidArgumentException("metric \"{$name}\" must be a finite number");
        }
        $this->recorder->metric($name, $value);
    }

    /** @param array<string, int|float> $values */
    public function metrics(array $values): void
    {
        foreach ($values as $name => $value) {
            $this->metric((string) $name, $value);
        }
    }

    /** True once the job's timeout has passed. Honour it if the work can stop. */
    public function aborted(): bool
    {
        return $this->signal->aborted();
    }

    /** A logged value as text, the way the SDK writes it. */
    public static function stringify(mixed $part): string
    {
        if (is_string($part)) {
            return Js::wellFormed($part);
        }
        if ($part instanceof \Throwable) {
            return Output::errorName($part) . ': ' . Js::wellFormed($part->getMessage());
        }
        try {
            return Js::stringify($part);
        } catch (\Throwable) {
            try {
                return is_object($part) ? Js::stringify(get_object_vars($part)) : Js::string($part);
            } catch (\Throwable) {
                return Js::string($part);
            }
        }
    }
}
