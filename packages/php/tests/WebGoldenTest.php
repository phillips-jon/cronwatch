<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Alerts\Custom;
use Cronwatch\Cronwatch;
use Cronwatch\Job\JobContext;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Tests\Support\Clock;
use Cronwatch\Web\Dashboard;
use Cronwatch\Web\PsrHandler;
use Cronwatch\Web\Request;
use Cronwatch\Web\Response;
use Nyholm\Psr7\Factory\Psr17Factory;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * Replays packages/ruby/test/web/golden.json, the SDK routes' answers to a
 * fixed seed (written by golden.mjs), against Cronwatch\Web\Dashboard seeded
 * the same way, and compares status, headers and body byte for byte. Run ids
 * are random on both sides, so each becomes <id:N> in order of first
 * appearance. The gem's test/web_golden_test.rb and the Python package's
 * tests/test_web_golden.py replay the same file.
 *
 * Each capture goes in three ways: a Request made by hand (handle()), the
 * superglobals a server would fill (Request::fromGlobals(), which serve()
 * reads), and a PSR-7 request through PsrHandler.
 */
final class WebGoldenTest extends TestCase
{
    private const GOLDEN = __DIR__ . '/../../ruby/test/web/golden.json';
    private const UUID = '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/';
    private const MIN = Clock::MIN;
    private const HOUR = Clock::HOUR;
    private const DAY = 24 * Clock::HOUR;
    /** The one header the SDK leaves to the server. */
    private const IGNORED_HEADERS = ['content-length'];

    /** @var list<string> What the seed and the requests reported to onError: nothing, however far off a run's start is. */
    private static array $errors = [];

    /** The seed in golden.mjs, step for step. */
    private static function seed(): Cronwatch
    {
        $clock = new Clock();
        self::$errors = [];
        $cw = new Cronwatch(
            store: new MemoryStore(),
            alerts: [new Custom('capture', fn () => null)],
            cronSecret: false,
            now: $clock,
            onError: function (\Throwable $error, string $context): void {
                self::$errors[] = "{$context}: {$error->getMessage()}";
            },
        );
        $quietly = function (callable $fn): void {
            try {
                $fn();
            } catch (\Throwable) {
                // A failed run is part of the seed.
            }
        };
        $nightly = $cw->job('nightly-report', [
            'schedule' => '0 2 * * *', 'timezone' => 'UTC', 'grace' => '15m', 'maxDuration' => '10m', 'budget' => ['cost' => 2],
            'expect' => 'Report written', 'failuresBeforeAlert' => 2, 'description' => 'Builds the <b>PDF</b>', 'tags' => ['reports', '<t>'],
        ]);
        $durations = [2000, 2500, 90_000, 3100, 1800];
        foreach ($durations as $i => $duration) {
            $clock->set(Clock::T0 - (5 - $i) * self::DAY - 7 * self::HOUR - 30 * self::MIN);
            $quietly(fn () => $nightly->run(function (JobContext $job) use ($i, $duration, $clock): void {
                $job->log($i === 3 ? 'Wrote nothing' : 'Report written:', "report-{$i}.pdf");
                $job->metric('cost', $i === 4 ? 2.5 : 1.2);
                $job->metric('rows', 40 + $i);
                $job->metric('2', 0.123456);
                $clock->advance($duration);
            }));
        }

        $broken = $cw->job('broken', ['expect' => 'done']);
        $clock->set(Clock::T0 - 2 * self::HOUR);
        $quietly(fn () => $broken->run(function (JobContext $job) use ($clock): void {
            $job->log('half way <script>alert(1)</script>');
            $clock->advance(450);
        }));

        $sync = $cw->job('sync-users', ['schedule' => '*/15 * * * *', 'grace' => 60_000, 'timeout' => '5m']);
        $clock->set(Clock::T0 - 3 * self::HOUR);
        $quietly(fn () => $sync->run(function () use ($clock): void {
            $clock->advance(12_345);
        }));

        $cw->job('never-ran', ['schedule' => '0 * * * *']);

        // A run as a foreign or damaged row could hold it: started before the
        // year 1, so the pages write it in words rather than as a date.
        $farBack = $cw->job('far-back', ['timeout' => '5m', 'expect' => 'far']);
        $clock->set(-62_135_596_800_001);
        $quietly(fn () => $farBack->run(function () use ($clock): void {
            $clock->advance(1000);
        }));

        // Cron jobs whose last run is as far off: counted from the first
        // millisecond of the year 1, the first is due then (and is missed at
        // the check); after 9999 the other is never due again.
        $farCronBack = $cw->job('far-cron-back', ['schedule' => '0 2 * * *', 'timezone' => 'UTC', 'grace' => '10m']);
        $clock->set(-62_135_596_800_001);
        $farCronBack->run(function () use ($clock): void {
            $clock->advance(1000);
        });
        $farCronAhead = $cw->job('far-cron-ahead', ['schedule' => '0 2 * * *', 'timezone' => 'UTC', 'grace' => '10m']);
        $clock->set(253_402_300_800_000);
        $farCronAhead->run(function () use ($clock): void {
            $clock->advance(1000);
        });
        $clock->set(Clock::T0);
        return $cw;
    }

    /** @return array<string, array{string}> */
    public static function ways(): array
    {
        return ['handle' => ['handle'], 'globals' => ['globals'], 'psr' => ['psr']];
    }

    #[DataProvider('ways')]
    public function testTheJsonApiAndPagesMatchTheSdkRoutes(string $way): void
    {
        $data = json_decode((string) file_get_contents(self::GOLDEN), true, 512, JSON_THROW_ON_ERROR);
        $this->assertSame(Clock::T0, $data['t0']);
        $this->assertCount(63, $data['captures']);
        $cw = self::seed();
        $web = $cw->routes(token: 'tok', basePath: '/cronwatch');
        $ids = [];
        $number = function (array $m) use (&$ids): string {
            return $ids[$m[0]] ??= '<id:' . count($ids) . '>';
        };
        foreach ($data['captures'] as $capture) {
            $label = "{$capture['method']} {$capture['path']}";
            $path = (string) preg_replace_callback('/\{run:([^:}]+):(\d+)\}/', fn (array $m) => $cw->runs($m[1], 50)[(int) $m[2]]->id, $capture['path']);
            $response = self::deliver($way, $web, $capture['method'], $path, (array) $capture['headers'], $capture['body']);
            // PNGs are kept as base64, so the fixture stays text.
            $body = $response->header('content-type') === 'image/png'
                ? 'base64:' . base64_encode($response->body)
                : (string) preg_replace_callback(self::UUID, $number, $response->body);
            $this->assertSame($capture['status'], $response->status, $label);
            $headers = array_diff_key($response->headers, array_flip(self::IGNORED_HEADERS));
            $expected = $capture['responseHeaders'];
            ksort($headers);
            ksort($expected);
            $this->assertSame($expected, $headers, $label);
            $this->assertSame($capture['responseBody'], $body, $label);
        }
        $this->assertSame([], self::$errors);
    }

    /** @param array<string, string> $headers */
    private static function deliver(string $way, Dashboard $web, string $method, string $path, array $headers, ?string $body): Response
    {
        $url = "http://app.test{$path}";
        if ($way === 'handle') {
            return $web->handle(Request::create($method, $url, $headers, $body ?? ''));
        }
        if ($way === 'globals') {
            // What PHP-FPM or Apache hands a script: the request target as sent, the headers as HTTP_*.
            $server = ['REQUEST_METHOD' => $method, 'REQUEST_URI' => $path, 'QUERY_STRING' => (string) parse_url($url, PHP_URL_QUERY),
                'SCRIPT_NAME' => '/index.php', 'HTTP_HOST' => 'app.test', 'SERVER_NAME' => 'app.test', 'SERVER_PORT' => '80'];
            foreach ($headers as $name => $value) {
                $key = strtoupper(str_replace('-', '_', $name));
                $server[in_array($key, ['CONTENT_TYPE', 'CONTENT_LENGTH'], true) ? $key : "HTTP_{$key}"] = $value;
            }
            return $web->handle(Request::fromGlobals($server, $body ?? ''));
        }
        $factory = new Psr17Factory();
        // A server request carries the target as sent in its server parameters, as one built from $_SERVER does.
        $request = $factory->createServerRequest($method, $url, ['REQUEST_URI' => $path, 'SCRIPT_NAME' => '/index.php']);
        foreach ($headers as $name => $value) {
            $request = $request->withHeader($name, $value);
        }
        $request = $request->withBody($factory->createStream($body ?? ''));
        $psr = (new PsrHandler($web, $factory, $factory))->handle($request);
        $out = [];
        foreach ($psr->getHeaders() as $name => $values) {
            $out[strtolower($name)] = implode(', ', $values);
        }
        return new Response($psr->getStatusCode(), $out, (string) $psr->getBody());
    }
}
