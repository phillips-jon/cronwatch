<?php

declare(strict_types=1);

/**
 * A job that ends its process mid-run, for ShutdownTest: it calls exit(), or
 * runs out of memory, which no catch sees.
 *
 *     php interrupted.php exit|memory <sqlite file>
 */

use Cronwatch\Cronwatch;
use Cronwatch\Store\SqliteStore;

require __DIR__ . '/../bootstrap.php';

[, $mode, $file] = $argv;
$cw = new Cronwatch(store: new SqliteStore($file), alerts: [], cronSecret: false);
$cw->job('nightly')->run(function ($job) use ($mode): void {
    $job->log('started');
    if ($mode === 'exit') {
        exit(3);
    }
    ini_set('memory_limit', '64M');
    $hoard = [];
    while (true) {
        $hoard[] = str_repeat('x', 1024 * 1024);
    }
});
