<?php

declare(strict_types=1);

namespace Cronwatch\Job;

/**
 * A cancellation flag, like JavaScript's AbortSignal. A job's signal aborts
 * once the job's timeout has passed; triage gets one that aborts when the
 * client stops waiting. PHP cannot interrupt the code it runs, so nothing is
 * stopped: code that can stop early checks aborted(), or asks remaining()
 * for the time it has left (to pass on as an HTTP timeout, say).
 */
final class AbortSignal
{
    private ?float $deadline;
    private bool $aborted = false;
    private bool $settled = false;

    /** @param int|float|null $timeoutMs milliseconds from now until it aborts on its own, or null for never */
    public function __construct(int|float|null $timeoutMs = null)
    {
        $this->deadline = $timeoutMs === null ? null : hrtime(true) / 1e9 + $timeoutMs / 1000;
    }

    public function aborted(): bool
    {
        if (!$this->aborted && !$this->settled && $this->deadline !== null && hrtime(true) / 1e9 >= $this->deadline) {
            $this->aborted = true;
        }
        return $this->aborted;
    }

    public function abort(): void
    {
        if (!$this->settled) {
            $this->aborted = true;
        }
    }

    /** Milliseconds until it aborts on its own: 0 once aborted, null when it never will. */
    public function remainingMs(): ?int
    {
        if ($this->aborted()) {
            return 0;
        }
        return $this->deadline === null ? null : max(0, (int) floor(($this->deadline - hrtime(true) / 1e9) * 1000));
    }

    /** Throws AbortError when aborted, for a loop that should stop there. */
    public function throwIfAborted(): void
    {
        if ($this->aborted()) {
            throw new AbortError('This operation was aborted');
        }
    }

    /** Called when the work is over: a timeout that passes later no longer aborts it. */
    public function settle(): void
    {
        $this->aborted();
        $this->settled = true;
    }
}
