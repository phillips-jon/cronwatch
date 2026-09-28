<?php

// Serves the dashboard with serve() (the superglobals in, header() and echo
// out) under `php -S`, for packages/mcp/test/php-web.test.ts, which drives
// @cronwatch/mcp against it, and for WebServeTest. As a front controller
// behind a rewrite would see it: every path comes here, and the dashboard
// answers under /cronwatch (its default base path), anything else is a 404.
//
//   CW_WEB_DB=/tmp/cw.db php -S 127.0.0.1:PORT packages/php/tests/servers/web.php
//
// Each request is a PHP process of its own, so the jobs live in a SQLite
// file (CW_WEB_DB), seeded by the first request like the MCP tests' own end
// to end case: a "nightly" job with one good run and one failed one, and a
// fixed clock. Alerts are written to standard error, which php -S passes
// through, as "alert <job> <type>" lines.

declare(strict_types=1);

require __DIR__ . '/../../vendor/autoload.php';

use Cronwatch\Alert;
use Cronwatch\Alerts\Custom;
use Cronwatch\Cronwatch;
use Cronwatch\Job\JobContext;
use Cronwatch\Js;
use Cronwatch\Store\SqliteStore;

$db = (string) getenv('CW_WEB_DB');
$seeded = is_file($db);
$now = Js::dateUtc(2026, 0, 5, 2);
$clock = function () use (&$now): int {
    return $now;
};
$channel = new Custom('test', function (Alert $alert): void {
    file_put_contents('php://stderr', "alert {$alert->job} {$alert->type}\n");
});
$cw = new Cronwatch(store: new SqliteStore($db), alerts: [$channel], cronSecret: false, now: $clock);
if (!$seeded) {
    // Declared only while seeding: a job declared on every request would come back after the MCP test forgets it.
    $nightly = $cw->job('nightly', ['schedule' => '0 2 * * *', 'timezone' => 'UTC', 'grace' => '15m']);
    $nightly->run(fn (JobContext $job) => $job->log('step 1'));
    $now += 60_000;
    try {
        $nightly->run(function (JobContext $job): void {
            $job->log('step 2');
            throw new RuntimeException('db down');
        });
    } catch (RuntimeException) {
        // The failed run is the seed.
    }
}
$now = Js::dateUtc(2026, 0, 5, 2, 1);

$path = (string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);
if ($path !== '/cronwatch' && !str_starts_with($path, '/cronwatch/')) {
    http_response_code(404);
    header('Content-Type: text/plain');
    echo 'not found';
    return;
}
$cw->routes(token: 'tok')->serve();
