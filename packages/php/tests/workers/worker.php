<?php

declare(strict_types=1);

/**
 * One process of a multi-process test (FinishOnceTest). It opens the store
 * the test names, declares the job, says it is ready, waits for the go file
 * so every process acts at the same moment, does its part, and prints what
 * happened as JSON: the runs it recorded, its alerts and its errors.
 *
 *     php worker.php '{"store": {...}, "action": "...", "ready": "...", "go": "...", ...}'
 */

use Cronwatch\Alert;
use Cronwatch\Cronwatch;
use Cronwatch\Run;
use Cronwatch\Store\MysqlStore;
use Cronwatch\Store\SqliteStore;
use Cronwatch\Tests\Support\Capture;
use Cronwatch\Tests\Support\FlakyStore;

require __DIR__ . '/../bootstrap.php';

$config = json_decode($argv[1], true, 512, JSON_THROW_ON_ERROR);
$spec = $config['store'];
$store = $spec['kind'] === 'sqlite' ? new SqliteStore($spec['path']) : new MysqlStore($spec['url'], prefix: $spec['prefix']);
if ($config['slowReads'] ?? false) {
    // State reads that take a while, as over a network: processes reading at
    // about the same time all get the old state before any of them writes.
    $store = new FlakyStore($store);
    $store->hooks['getState'] = function (\Closure $next, array $args) {
        $state = $next(...$args);
        usleep(25_000);
        return $state;
    };
}
$alerts = new Capture();
$errors = [];
$cw = new Cronwatch(
    store: $store,
    alerts: [$alerts],
    cronSecret: false,
    now: fn () => $config['now'],
    onError: function (\Throwable $error, string $where) use (&$errors): void {
        $errors[] = "{$where}: {$error->getMessage()}";
    },
);
$job = $cw->job($config['job'], $config['options'] ?? []);
$cw->jobs();

touch($config['ready']);
$deadline = microtime(true) + 30;
while (!file_exists($config['go'])) {
    if (microtime(true) > $deadline) {
        fwrite(STDERR, "no go file\n");
        exit(1);
    }
    usleep(500);
}

$recorded = [];
switch ($config['action']) {
    case 'fail':
        // Resume a run another process started, and fail it.
        $run = $cw->resumeRun($config['job'], $config['id'])->fail(new \RuntimeException('upstream 502'));
        $recorded[] = $run?->id;
        break;
    case 'record':
        // Record one finished run from a source.
        $cw->recordRun(Run::fromJson($config['run']));
        break;
    case 'startFinish':
        // Start each id and finish it, as every other process does at once.
        foreach ($config['ids'] as $id) {
            $run = $job->start(id: $id)->finish("worker {$config['worker']}");
            $recorded[] = $run?->id;
        }
        break;
    case 'runFails':
        // Fail the job once.
        try {
            $job->run(function (): never {
                throw new \RuntimeException('boom');
            });
        } catch (\RuntimeException) {
        }
        break;
    default:
        throw new \LogicException("unknown action {$config['action']}");
}

$cw->close();
echo json_encode([
    'recorded' => array_values(array_filter($recorded)),
    'alerts' => array_map(fn (Alert $a) => $a->type, $alerts->alerts),
    'errors' => $errors,
], JSON_THROW_ON_ERROR);
