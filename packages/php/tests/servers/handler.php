<?php

// A job's handler()->serve() under `php -S`, for HandlerTest: a bare
// script answering from the superglobals, as public/cron/hook.php would.
//
//   CW_HANDLER_DB=/tmp/cw.db CRON_SECRET=... php -S 127.0.0.1:PORT packages/php/tests/servers/handler.php
//
// The job logs the request's path; ?fail=1 throws, ?answer=array returns an
// array response of 418, ?answer=psr a PSR-7 response of 503.

declare(strict_types=1);

require __DIR__ . '/../../vendor/autoload.php';

use Cronwatch\Cronwatch;
use Cronwatch\Job\JobContext;
use Cronwatch\Store\SqliteStore;
use Cronwatch\Web\Request;

$cw = new Cronwatch(store: new SqliteStore((string) getenv('CW_HANDLER_DB')), alerts: [], onError: fn () => null);
$cw->job('hook')->handler(function (JobContext $job, Request $request) {
    $job->log("{$request->method} {$request->path}");
    $answer = $request->param('answer');
    if ($request->param('fail') === '1') {
        throw new RuntimeException("no luck\nsecond line");
    }
    if ($answer === 'array') {
        return ['status' => 418, 'headers' => ['content-type' => 'text/plain', 'x-kind' => 'array'], 'body' => 'teapot'];
    }
    if ($answer === 'psr') {
        $factory = new Nyholm\Psr7\Factory\Psr17Factory();
        return $factory->createResponse(503)->withHeader('X-Kind', 'psr')->withBody($factory->createStream('down'));
    }
    return null;
})->serve();
