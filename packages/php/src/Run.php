<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * One run of a job. Times are epoch milliseconds, as in the SDK, so stored
 * rows are identical whichever language wrote them.
 */
final class Run
{
    /**
     * @param string $status "running", "ok", "failed", or "timeout" (see RunStatus)
     * @param string|null $output lines logged, or the string the job returned, capped at 16 KB
     * @param array<string, int|float> $metrics
     * @param string $trigger what started the run: "run", "start", or a value you pass
     */
    public function __construct(
        public string $id,
        public string $job,
        public string $status,
        public int|float $startedAt,
        public int|float|null $finishedAt = null,
        public int|float|null $durationMs = null,
        public ?string $error = null,
        public ?string $output = null,
        public array $metrics = [],
        public string $trigger = 'run',
    ) {
    }

    /** A run from its JSON shape (camelCase keys), or from a decoded object. */
    public static function fromJson(array|\stdClass|self $data): self
    {
        if ($data instanceof self) {
            return $data;
        }
        $f = Js::fields($data);
        $metrics = [];
        foreach (Js::fields($f['metrics'] ?? []) as $name => $value) {
            $metrics[$name] = $value;
        }
        return new self(
            id: (string) ($f['id'] ?? ''),
            job: (string) ($f['job'] ?? ''),
            status: (string) ($f['status'] ?? ''),
            startedAt: $f['startedAt'] ?? 0,
            finishedAt: $f['finishedAt'] ?? null,
            durationMs: $f['durationMs'] ?? null,
            error: $f['error'] ?? null,
            output: $f['output'] ?? null,
            metrics: $metrics,
            trigger: (string) ($f['trigger'] ?? 'run'),
        );
    }

    /**
     * A run inside a queued alert, read leniently: it comes from a stored
     * state, which a foreign or hand-edited row may hold anything in. A start
     * that is not a number reads as 0, a finish or duration as null, an error
     * or output that is not text as null, metrics that are not an object as
     * none (and of an object, only the numbers), an id, job, or status that is
     * not a string or a number as "", and a trigger that is not text as
     * "run", so one odd value never makes the job's state unreadable. (fromJson() takes a run given in code, whose
     * wrong types are an error to report.)
     *
     * @internal
     */
    public static function fromStored(array|\stdClass|self $data): self
    {
        if ($data instanceof self) {
            return $data;
        }
        $f = Js::fields($data);
        $metrics = [];
        $stored = $f['metrics'] ?? null;
        if ($stored instanceof \stdClass || (is_array($stored) && !array_is_list($stored))) {
            foreach (Js::fields($stored) as $name => $value) {
                if (Js::isNumber($value)) {
                    $metrics[$name] = $value;
                }
            }
        }
        $number = fn (mixed $value): int|float|null => Js::isNumber($value) ? $value : null;
        $text = fn (mixed $value): ?string => is_string($value) ? $value : null;
        $name = fn (mixed $value): string => is_string($value) ? $value : (Js::isNumber($value) ? Js::number($value) : '');
        return new self(
            id: $name($f['id'] ?? null),
            job: $name($f['job'] ?? null),
            status: $name($f['status'] ?? null),
            startedAt: $number($f['startedAt'] ?? null) ?? 0,
            finishedAt: $number($f['finishedAt'] ?? null),
            durationMs: $number($f['durationMs'] ?? null),
            error: $text($f['error'] ?? null),
            output: $text($f['output'] ?? null),
            metrics: $metrics,
            trigger: $text($f['trigger'] ?? null) ?? 'run',
        );
    }

    /** The SDK's JSON shape, in its key order. */
    public function toJson(): array
    {
        return [
            'id' => $this->id,
            'job' => $this->job,
            'status' => $this->status,
            'startedAt' => $this->startedAt,
            'finishedAt' => $this->finishedAt,
            'durationMs' => $this->durationMs,
            'error' => $this->error,
            'output' => $this->output,
            'metrics' => Js::obj($this->metrics),
            'trigger' => $this->trigger,
        ];
    }

    public function isRunning(): bool
    {
        return $this->status === RunStatus::RUNNING;
    }

    public function isOk(): bool
    {
        return $this->status === RunStatus::OK;
    }
}
