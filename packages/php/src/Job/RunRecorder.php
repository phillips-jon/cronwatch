<?php

declare(strict_types=1);

namespace Cronwatch\Job;

use Cronwatch\Js;
use Cronwatch\Output;
use Cronwatch\Run;

/**
 * Collects a run's output and metrics while its function runs (job.ts).
 *
 * @internal
 */
final class RunRecorder
{
    /** Lines are dropped from the front once the output is well past the cap; capOutput trims it exactly at the end. */
    public const KEEP = 64 * 1024;

    /** @var array<int, string> The lines kept, from index $first on. */
    private array $lines = [];
    private int $first = 0;
    private int $size = 0;
    /** @var list<string> The first lines logged, up to the cap. */
    private array $head = [];
    private int $headSize = 0;
    /** Whether any line has been dropped from $lines: what expectText needs once the output runs long. */
    private bool $dropped = false;
    /** @var array<string, int|float> */
    private array $metrics = [];
    public readonly AbortSignal $signal;
    public readonly JobContext $context;

    public function __construct(Run $run, int|float|null $timeoutMs)
    {
        $this->signal = new AbortSignal($timeoutMs);
        $this->context = new JobContext($run, $this->signal, $this);
    }

    public function log(string $line): void
    {
        $length = Js::length16($line);
        if ($this->headSize < Output::OUTPUT_CAP) {
            $this->head[] = $line;
            $this->headSize += $length + 1;
        }
        $this->lines[] = $line;
        $this->size += $length + 1;
        while ($this->size > self::KEEP && count($this->lines) > 1) {
            $this->size -= Js::length16($this->lines[$this->first]) + 1;
            unset($this->lines[$this->first]);
            $this->first++;
            $this->dropped = true;
        }
    }

    public function metric(string $name, int|float $value): void
    {
        $this->metrics[$name] = $value;
    }

    public function output(): ?string
    {
        return $this->lines === [] ? null : Output::capOutput(implode("\n", $this->lines));
    }

    /**
     * What an expect rule is checked against: everything logged, or when that
     * ran long, the first 16 KB and the last 16 KB. The stored output keeps
     * only the tail, so a "done" line printed early would otherwise be lost.
     */
    public function expectText(): ?string
    {
        if ($this->lines === []) {
            return null;
        }
        $all = implode("\n", $this->lines);
        if (!$this->dropped && Js::length16($all) <= 2 * Output::OUTPUT_CAP) {
            return $all;
        }
        return Js::head16(implode("\n", $this->head), Output::OUTPUT_CAP) . "\n" . Js::tail16($all, Output::OUTPUT_CAP);
    }

    /** @return array<string, int|float> */
    public function metrics(): array
    {
        return $this->metrics;
    }
}
