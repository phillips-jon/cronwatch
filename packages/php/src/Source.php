<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * Runs that happen somewhere CronWatch cannot wrap, such as inside the
 * database. check() calls sync() on each source first, so what it records is
 * evaluated in the same check. The host is the client: job(), recordRun(),
 * $store, now() and onError().
 */
interface Source
{
    public function name(): string;

    /**
     * Declare the jobs and record their new runs. Returns the alerts recording them sent.
     *
     * @return list<Alert>
     */
    public function sync(Cronwatch $host): array;
}
