<?php

declare(strict_types=1);

/**
 * A job that fails, in a process that ends while its alert goes out, for
 * OutboxTest: in the triage call, before any channel is reached, or just
 * after a channel took the alert (it writes the alert's type to the marker
 * file first), before the process records that.
 *
 *     php dies-sending.php triage|accepted <sqlite file> <now> <marker file>
 */

use Cronwatch\Alert;
use Cronwatch\Alerts\Custom;
use Cronwatch\Cronwatch;
use Cronwatch\Store\SqliteStore;

require __DIR__ . '/../bootstrap.php';

[, $mode, $file, $now, $marker] = $argv;
$channel = new Custom('first', function (Alert $alert) use ($mode, $marker): void {
    file_put_contents($marker, $alert->type, FILE_APPEND);
    if ($mode === 'accepted') {
        exit(0);
    }
});
$cw = new Cronwatch(
    store: new SqliteStore($file),
    now: fn () => (int) $now,
    alerts: [$channel],
    cronSecret: null,
    triage: $mode === 'triage' ? function (): never {
        exit(0);
    } : null,
);
$cw->run('nightly', function (): never {
    throw new RuntimeException('disk full');
});
