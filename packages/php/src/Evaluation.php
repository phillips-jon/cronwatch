<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * A job's next state and the alerts that should go out, as an evaluation decides them.
 *
 * @internal
 */
class Evaluation
{
    /** @param list<AlertDraft> $alerts */
    public function __construct(
        public JobState $state,
        public array $alerts,
    ) {
    }
}
