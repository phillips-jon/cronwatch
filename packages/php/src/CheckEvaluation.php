<?php

declare(strict_types=1);

namespace Cronwatch;

/** What a check decides for one job, with when it is next expected and when the run it waits for was due. */
final class CheckEvaluation extends Evaluation
{
    /** @param list<AlertDraft> $alerts */
    public function __construct(
        JobState $state,
        array $alerts,
        public int|float|null $nextExpectedAt,
        public int|float|null $dueAt,
    ) {
        parent::__construct($state, $alerts);
    }
}
