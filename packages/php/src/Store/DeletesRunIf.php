<?php

declare(strict_types=1);

namespace Cronwatch\Store;

/**
 * A store that can take back a run it recorded, only while the run is still
 * of one job and in one status. The SDK has no counterpart: it is how a
 * Laravel queued job's attempt that released itself back onto the queue
 * without an exception (rate limited, WithoutOverlapping, a deliberate
 * release) leaves no run behind, neither a failure nor a success.
 */
interface DeletesRunIf
{
    /**
     * Delete the run `id` only when its stored job is `job` and its status is
     * `status` (SQL: DELETE ... WHERE id = ? AND job = ? AND status = ?).
     * Returns whether it deleted.
     */
    public function deleteRunIf(string $id, string $job, string $status): bool;
}
