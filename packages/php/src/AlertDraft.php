<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * An alert before it has a title and message. See Format::composeAlert().
 * `details` has the SDK's camelCase keys: missed {dueAt, deadline, graceMs,
 * lastRunAt}, failed and stuck {consecutiveFailures, threshold}, slow
 * {durationMs, thresholdMs, basis}, over_budget and under_floor {breaches:
 * [{metric, value, limit, basis}]}, recovered {after, reason?, since?}.
 *
 * @internal
 */
final class AlertDraft
{
    /** @param array<string, mixed> $details */
    public function __construct(
        public string $type,
        public ?Run $run,
        public array $details,
    ) {
    }

    public function toJson(): array
    {
        return ['type' => $this->type, 'run' => $this->run?->toJson(), 'details' => Alert::detailsJson($this->details)];
    }
}
