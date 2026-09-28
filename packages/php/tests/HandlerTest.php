<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Cronwatch;
use Cronwatch\Env;
use Cronwatch\Job\Handler;
use Cronwatch\Job\JobContext;
use Cronwatch\Tests\Support\Clients;
use Cronwatch\Web\PsrJobHandler;
use Cronwatch\Web\Request;
use Cronwatch\Web\Response;
use Cronwatch\Web\ResponseStatus;
use Nyholm\Psr7\Factory\Psr17Factory;
use Nyholm\Psr7\ServerRequest;
use PHPUnit\Framework\TestCase;

/**
 * $job->handler(), the SDK's fetch-style job handler (client.test.ts's and
 * client-hardening.test.ts's handler tests), a response as a run's outcome,
 * and the adapters: serve() under php -S, PSR-15, and the request kinds the
 * bearer is read from. The Laravel and Symfony adapters are tested with
 * their frameworks (tests/Laravel, tests/Symfony).
 */
final class HandlerTest extends TestCase
{
    use Clients;

    private const ENV = ['CRONWATCH_ENV', 'APP_ENV', 'WP_ENVIRONMENT_TYPE', 'CRON_SECRET'];

    /** @var array<string, array{string|false, mixed, mixed}> */
    private array $savedEnv = [];

    protected function setUp(): void
    {
        foreach (self::ENV as $name) {
            $this->savedEnv[$name] = [getenv($name), $_ENV[$name] ?? null, $_SERVER[$name] ?? null];
            putenv($name);
            unset($_ENV[$name], $_SERVER[$name]);
        }
    }

    protected function tearDown(): void
    {
        foreach ($this->savedEnv as $name => [$env, $superEnv, $server]) {
            putenv($env === false ? $name : "{$name}={$env}");
            if ($superEnv !== null) {
                $_ENV[$name] = $superEnv;
            }
            if ($server !== null) {
                $_SERVER[$name] = $server;
            }
        }
    }

    private static function get(array $headers = [], string $url = 'http://x/api/cron/hourly'): Request
    {
        return Request::create('GET', $url, $headers);
    }

    /** @return array<string, mixed> */
    private static function body(Response $response): array
    {
        return json_decode($response->body, true, flags: JSON_THROW_ON_ERROR);
    }

    public function testHandlerChecksTheBearerSecretAndReportsTheRun(): void
    {
        $cw = $this->make(['cronSecret' => 's3cret']);
        $handler = $cw->job('hourly', ['schedule' => '@hourly'])->handler(function (JobContext $j, Request $request) {
            $j->log($request->path);
            if ($request->header('x-fail') !== null) {
                throw new \RuntimeException("nope\nat the second line");
            }
            return ['fine' => true];
        });
        $noAuth = $handler->respond(self::get());
        $this->assertSame(401, $noAuth->status);
        $this->assertSame('{"ok":false,"error":"Unauthorized"}', $noAuth->body);
        $ok = $handler->respond(self::get(['authorization' => 'Bearer s3cret']));
        $this->assertSame(200, $ok->status);
        $run = $cw->runs('hourly')[0];
        $this->assertSame('{"ok":true,"job":"hourly","run":"' . $run->id . '","status":"ok","durationMs":0}', $ok->body);
        $this->assertSame(['content-type' => 'application/json; charset=utf-8', 'cache-control' => 'no-store'], $ok->headers);
        $this->assertSame('handler', $run->trigger);
        $failed = $handler->respond(self::get(['authorization' => 'Bearer s3cret', 'x-fail' => '1']));
        $this->assertSame(500, $failed->status);
        $this->assertSame(false, self::body($failed)['ok']);
        $this->assertSame('failed', self::body($failed)['status']);
        $this->assertSame('RuntimeException: nope', self::body($failed)['error'], 'the first line only');
        $runs = $cw->runs('hourly');
        $this->assertCount(2, $runs);
        $this->assertSame('/api/cron/hourly', $runs[1]->output);
        $this->assertSame(401, $handler->respond(self::get(['authorization' => 'Bearer s3cret2']))->status, 'compared exactly');
        $this->assertSame(401, $handler->respond(self::get(['authorization' => 'Bearer s3cre']))->status);
        $this->assertSame(401, $handler->respond(self::get(['authorization' => 'bearer s3cret']))->status);
        $this->assertCount(2, $cw->runs('hourly'), 'a refused request runs nothing');
    }

    public function testAHandlerReturningAResponsePassesItThroughAnd4xxOr5xxCountAsFailure(): void
    {
        $cw = $this->make();
        $answer = new Response(503, ['content-type' => 'text/plain'], 'bad');
        $handler = $cw->job('h')->handler(fn () => $answer);
        $res = $handler->respond(self::get());
        $this->assertSame($answer, $res);
        $this->assertSame('HTTP 503', $cw->runs('h')[0]->error);
        $this->assertSame(['failed'], $this->capture->types());

        $fine = $cw->job('fine')->handler(fn () => new Response(204, [], ''));
        $this->assertSame(204, $fine->respond(self::get())->status);
        $this->assertSame('ok', $cw->runs('fine')[0]->status);
    }

    public function testHandlerFailsClosedWithoutASecretOutsideDevelopment(): void
    {
        $cw = $this->make(['cronSecret' => '']);
        $ran = 0;
        $handler = $cw->job('closed')->handler(function () use (&$ran): void {
            $ran++;
        });
        $this->assertNull($cw->cronSecret, 'an empty secret is no secret');
        $res = $handler->respond(self::get());
        $this->assertSame(503, $res->status);
        $this->assertSame('{"ok":false,"error":"' . Handler::NO_SECRET . '"}', $res->body);
        $this->assertStringContainsString('CRON_SECRET', self::body($res)['error']);
        $handler->respond(self::get());
        $this->assertSame(0, $ran);
        $this->assertSame(['handler'], $this->wheres(), 'reported once');
        $this->assertSame(['handler() refused a request because no CRON_SECRET is set; pass secret: false to allow unauthenticated requests'], $this->messages());

        // Opting out with false runs the job, and does not show the error to the caller.
        $open = $cw->job('open')->handler(fn () => throw new \RuntimeException('private detail'), secret: false);
        $failed = $open->respond(self::get());
        $this->assertSame(500, $failed->status);
        $this->assertArrayNotHasKey('error', self::body($failed));

        putenv('CRONWATCH_ENV=development');
        $this->assertSame(200, $handler->respond(self::get())->status);
        $this->assertSame(1, $ran);
    }

    public function testTheClientSecretIsUsedUnlessTheHandlerHasItsOwnAndFalseOptsOutForEveryHandler(): void
    {
        putenv('CRON_SECRET=from-env');
        $cw = $this->make(['cronSecret' => null]);
        $job = $cw->job('j');
        $this->assertSame(200, $job->handler(fn () => null)->respond(self::get(['authorization' => 'Bearer from-env']))->status);
        $own = $job->handler(fn () => null, secret: 'mine');
        $this->assertSame('mine', $own->secret);
        $this->assertSame(401, $own->respond(self::get(['authorization' => 'Bearer from-env']))->status);
        $this->assertSame(200, $own->respond(self::get(['authorization' => 'Bearer mine']))->status);
        $this->assertSame('from-env', $job->handler(fn () => null, secret: '')->secret, '"" counts as unset');

        $opted = $this->make(['cronSecret' => false]);
        $handler = $opted->job('j')->handler(fn () => null);
        $this->assertNull($handler->secret);
        $this->assertSame(200, $handler->respond(self::get())->status);
        $this->assertSame(200, $opted->job('k')->handler(fn () => null, secret: '')->respond(self::get())->status);
        $this->assertSame(401, $opted->job('m')->handler(fn () => null, secret: 'own')->respond(self::get())->status, 'its own secret still counts');
    }

    public function testTheBearerIsReadFromEveryKindOfRequest(): void
    {
        $this->assertSame('Bearer a', Handler::authorization(self::get(['Authorization' => 'Bearer a'])));
        $this->assertSame('Bearer b', Handler::authorization(['HTTP_AUTHORIZATION' => 'Bearer b']));
        $this->assertSame('Bearer c', Handler::authorization(['REDIRECT_HTTP_AUTHORIZATION' => 'Bearer c']));
        $this->assertSame('Bearer d', Handler::authorization(['headers' => ['AUTHORIZATION' => 'Bearer d']]));
        $this->assertSame('Bearer e', Handler::authorization(['headers' => ['authorization' => ['Bearer e']]]));
        $this->assertSame('Bearer f', Handler::authorization(new ServerRequest('GET', '/', ['Authorization' => 'Bearer f'])));
        $this->assertSame('', Handler::authorization(null));
        $this->assertSame('', Handler::authorization(new \stdClass()));
        $this->assertSame('', Handler::authorization([]));
    }

    public function testTheFunctionGetsTheRequestItWasGivenAndItsContextIsCurrent(): void
    {
        $cw = $this->make();
        $seen = [];
        $psr = new ServerRequest('POST', '/cron');
        $handler = $cw->job('seen')->handler(function (JobContext $job, mixed $request) use (&$seen): string {
            $seen[] = [$request, Cronwatch::current() === $job];
            return 'returned text';
        }, secret: false);
        $handler->respond($psr);
        $this->assertSame([[$psr, true]], $seen);
        $this->assertSame('returned text', $cw->runs('seen')[0]->output, 'a returned string is the output, as for run()');
    }

    public function testAResponseOfAnyKindFailsARunAt400OrMore(): void
    {
        $cw = $this->make();
        $factory = new Psr17Factory();
        $cases = [
            [new Response(500, []), 'HTTP 500'],
            [['status' => 404], 'HTTP 404'],
            [['status' => 429, 'headers' => [], 'body' => 'slow down'], 'HTTP 429'],
            [$factory->createResponse(503), 'HTTP 503 Service Unavailable'],
            [$factory->createResponse(502, ''), 'HTTP 502'],
            [$factory->createResponse(599, 'Custom Reason'), 'HTTP 599 Custom Reason'],
        ];
        foreach ($cases as $i => [$response, $error]) {
            $cw->job("r{$i}")->run(fn () => $response);
            $run = $cw->runs("r{$i}")[0];
            $this->assertSame(['failed', $error], [$run->status, $run->error], "case {$i}");
        }
        foreach ([new Response(200, []), ['status' => 302, 'headers' => ['location' => '/']], $factory->createResponse(399)] as $i => $response) {
            $this->assertSame($response, $cw->job("fine{$i}")->run(fn () => $response), 'run() returns it');
            $this->assertSame('ok', $cw->runs("fine{$i}")[0]->status);
        }
        // Arrays that are not responses, and things that only look like them, are results like any other.
        foreach ([['status' => 'ok'], ['status' => 500, 'rows' => 3], ['status' => 99], ['status' => 600], ['status' => 500.0], ['headers' => []]] as $value) {
            $this->assertNull(ResponseStatus::of($value), json_encode($value));
        }
        $this->assertNull(ResponseStatus::of(new class () {
            public function getStatusCode(): int
            {
                throw new \RuntimeException('not connected');
            }
        }), 'a response that cannot say its status is not one');
        $this->assertNull(ResponseStatus::of(new \RuntimeException('x', 500)));
    }

    public function testFinishWithAResponseFailsTheRunAt400OrMore(): void
    {
        $cw = $this->make();
        $job = $cw->job('later');
        $job->start(id: 'r-1')->finish(['result' => new Response(500, [])]);
        $job->start(id: 'r-2')->finish(['result' => ['status' => 201]]);
        $this->assertSame(['failed', 'HTTP 500'], [$cw->getRun('r-1')->status, $cw->getRun('r-1')->error]);
        $this->assertSame('ok', $cw->getRun('r-2')->status);
    }

    public function testThePsr15AdapterAnswersInPsr7(): void
    {
        $cw = $this->make(['cronSecret' => 's3cret']);
        $factory = new Psr17Factory();
        $seen = null;
        $own = new PsrJobHandler($cw->job('psr')->handler(function (JobContext $job, $request) use (&$seen): void {
            $seen = $request;
        }), $factory, $factory);
        $request = new ServerRequest('GET', 'https://app.example.com/cron/psr', ['Authorization' => 'Bearer s3cret']);
        $answer = $own->handle($request);
        $this->assertSame($request, $seen);
        $this->assertSame(200, $answer->getStatusCode());
        $this->assertSame('application/json; charset=utf-8', $answer->getHeaderLine('Content-Type'));
        $this->assertSame('no-store', $answer->getHeaderLine('Cache-Control'));
        $this->assertStringStartsWith('{"ok":true,"job":"psr","run":"', (string) $answer->getBody());
        $this->assertSame(401, $own->handle(new ServerRequest('GET', '/cron/psr'))->getStatusCode());

        $passed = $factory->createResponse(418);
        $through = new PsrJobHandler($cw->job('teapot')->handler(fn () => $passed), $factory, $factory);
        $this->assertSame($passed, $through->handle($request));
        $this->assertSame('HTTP 418 I\'m a teapot', $cw->runs('teapot')[0]->error);

        $array = new PsrJobHandler($cw->job('array')->handler(fn () => ['status' => 202, 'headers' => ['X-Queued' => '1'], 'body' => 'queued']), $factory, $factory);
        $answer = $array->handle($request);
        $this->assertSame([202, '1', 'queued'], [$answer->getStatusCode(), $answer->getHeaderLine('x-queued'), (string) $answer->getBody()]);
    }

    public function testInvokeAnswersAWebRequestWithAWebResponseAndMakesArraysOne(): void
    {
        $cw = $this->make();
        $handler = $cw->job('kinds')->handler(fn (JobContext $job, $request) => $request instanceof Request ? ['status' => 207, 'body' => ['a' => 1]] : null);
        $answer = $handler(self::get());
        $this->assertInstanceOf(Response::class, $answer);
        $this->assertSame([207, '{"a":1}'], [$answer->status, $answer->body]);
        $this->assertSame(200, $handler(['HTTP_AUTHORIZATION' => ''])->status);
    }

    public function testServeAnswersFromTheSuperglobalsUnderPhpS(): void
    {
        if (!extension_loaded('pdo_sqlite') || !function_exists('proc_open')) {
            $this->markTestSkipped('needs pdo_sqlite and proc_open');
        }
        $dir = sys_get_temp_dir() . '/cronwatch-handler-' . getmypid() . '-' . bin2hex(random_bytes(4));
        mkdir($dir);
        $probe = stream_socket_server('tcp://127.0.0.1:0');
        $name = (string) stream_socket_get_name($probe, false);
        fclose($probe);
        $port = (int) substr($name, strrpos($name, ':') + 1);
        $secret = 'serve-' . bin2hex(random_bytes(6));
        $server = proc_open(
            [PHP_BINARY, '-d', 'expose_php=1', '-S', "127.0.0.1:{$port}", __DIR__ . '/servers/handler.php'],
            [0 => ['file', '/dev/null', 'r'], 1 => ['file', "{$dir}/out.log", 'w'], 2 => ['file', "{$dir}/out.log", 'w']],
            $pipes,
            null,
            ['CW_HANDLER_DB' => "{$dir}/cw.db", 'CRON_SECRET' => $secret, 'PATH' => (string) getenv('PATH')],
        );
        try {
            self::waitFor($port);
            [$status, $headers, $body] = self::http($port, 'GET', '/cron/hook?x=1', "Bearer {$secret}");
            $this->assertSame(200, $status);
            $this->assertSame('application/json; charset=utf-8', $headers['content-type']);
            $this->assertSame('no-store', $headers['cache-control']);
            $this->assertArrayNotHasKey('x-powered-by', $headers);
            $this->assertMatchesRegularExpression('/^\{"ok":true,"job":"hook","run":"[0-9a-f-]{36}","status":"ok","durationMs":\d+\}$/', $body);
            $this->assertSame((string) strlen($body), $headers['content-length']);

            [$status, , $body] = self::http($port, 'GET', '/cron/hook', 'Bearer wrong');
            $this->assertSame([401, '{"ok":false,"error":"Unauthorized"}'], [$status, $body]);
            [$status, , $body] = self::http($port, 'POST', '/cron/hook?fail=1', "Bearer {$secret}");
            $this->assertSame(500, $status);
            $this->assertSame('RuntimeException: no luck', json_decode($body, true)['error']);
            [$status, $headers, $body] = self::http($port, 'GET', '/cron/hook?answer=array', "Bearer {$secret}");
            $this->assertSame([418, 'array', 'teapot'], [$status, $headers['x-kind'], $body]);
            [$status, $headers, $body] = self::http($port, 'GET', '/cron/hook?answer=psr', "Bearer {$secret}");
            $this->assertSame([503, 'psr', 'down'], [$status, $headers['x-kind'], $body]);
            [$status, $headers, $body] = self::http($port, 'HEAD', '/cron/hook', "Bearer {$secret}");
            $this->assertSame([200, ''], [$status, $body], 'HEAD runs the job and sends the headers only');
            [$status] = self::http($port, 'GET', '/cron/hook?slow=1', "Bearer {$secret}");
            $this->assertSame(500, $status);
            $this->assertFileExists("{$dir}/cw.db.alerted", 'an alert outlasting the request\'s time limit still goes out');

            $cw = new Cronwatch(store: new \Cronwatch\Store\SqliteStore("{$dir}/cw.db"), alerts: []);
            $runs = $cw->runs('hook');
            $this->assertSame(['ok', 'failed', 'failed', 'failed', 'ok'], array_reverse(array_map(fn ($r) => $r->status, $runs)));
            $this->assertSame(['HTTP 418', 'HTTP 503 Service Unavailable'], [$runs[2]->error, $runs[1]->error]);
            $this->assertSame('GET /cron/hook', $runs[4]->output);
            $cw->close();
        } finally {
            proc_terminate($server);
            proc_close($server);
            foreach (glob("{$dir}/*") ?: [] as $file) {
                @unlink($file);
            }
            @rmdir($dir);
        }
    }

    private static function waitFor(int $port): void
    {
        for ($i = 0; $i < 100; $i++) {
            $socket = @stream_socket_client("tcp://127.0.0.1:{$port}", $errno, $error, 0.1);
            if ($socket !== false) {
                fclose($socket);
                return;
            }
            usleep(50_000);
        }
        throw new \RuntimeException('php -S did not start');
    }

    /** @return array{int, array<string, string>, string} */
    private static function http(int $port, string $method, string $target, string $authorization): array
    {
        $socket = stream_socket_client("tcp://127.0.0.1:{$port}", $errno, $error, 5);
        fwrite($socket, "{$method} {$target} HTTP/1.1\r\nHost: 127.0.0.1:{$port}\r\nAuthorization: {$authorization}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        $raw = stream_get_contents($socket);
        fclose($socket);
        [$head, $body] = explode("\r\n\r\n", (string) $raw, 2);
        $lines = explode("\r\n", $head);
        $status = (int) explode(' ', array_shift($lines))[1];
        $headers = [];
        foreach ($lines as $line) {
            [$name, $value] = explode(':', $line, 2);
            $headers[strtolower(trim($name))] = trim($value);
        }
        return [$status, $headers, $body];
    }
}
