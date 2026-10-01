<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Cronwatch;
use Cronwatch\Job\JobContext;
use Cronwatch\JobDefinition;
use Cronwatch\Js;
use Cronwatch\Run;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Tests\Support\Clients;
use Cronwatch\Tests\Support\Clock;
use Cronwatch\Tests\Support\DelegatingStore;
use Cronwatch\Web\Dashboard;
use Cronwatch\Web\PsrMiddleware;
use Cronwatch\Web\Request;
use Cronwatch\Web\Response;
use Cronwatch\Web\Text;
use Nyholm\Psr7\Factory\Psr17Factory;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\RequestHandlerInterface;

/**
 * The SDK's routes tests (routes.test.ts, routes-security.test.ts,
 * routes-origin.test.ts, routes-pwa.test.ts and routes-timeline.test.ts)
 * against Cronwatch\Web\Dashboard, as the Python package's test_web.py has
 * them, plus what only PHP needs: the superglobals, a path-info mount, the
 * development token kept between requests, and the PSR-15 middleware.
 */
final class WebTest extends TestCase
{
    use Clients;

    private const MIN = Clock::MIN;
    private const HOUR = Clock::HOUR;
    private const T0 = Clock::T0;
    private const BEARER = ['authorization' => 'Bearer tok'];
    private const FORM = ['content-type' => 'application/x-www-form-urlencoded'];
    private const JSON = ['authorization' => 'Bearer tok', 'content-type' => 'application/json'];
    private const CSP = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";
    private const ENV = ['CRONWATCH_ENV', 'APP_ENV', 'WP_ENVIRONMENT_TYPE', 'CRONWATCH_TOKEN'];

    /** @var list<string> */
    private array $logged = [];
    /** @var list<string> */
    private array $tokenFiles = [];
    /** @var array<string, array{string|false, mixed, mixed}> */
    private array $savedEnv = [];

    protected function setUp(): void
    {
        // No environment names development unless a test says so, and no token comes from outside.
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
        foreach ($this->tokenFiles as $file) {
            @unlink($file);
        }
    }

    private static function cookie(): array
    {
        return ['cookie' => 'cronwatch_token=' . hash('sha256', 'cronwatch-cookie:tok')];
    }

    /** One request to the dashboard; a path is on http://app.test. */
    private static function send(Dashboard $web, string $method, string $url, array $headers = [], ?string $body = null): Response
    {
        return $web->handle(Request::create($method, str_starts_with($url, '/') ? "http://app.test{$url}" : $url, $headers, $body ?? ''));
    }

    private static function json(Response $response): mixed
    {
        return json_decode($response->body, true, 512, JSON_THROW_ON_ERROR);
    }

    /** A dashboard whose development token is kept in a file of this test's own, its sign-in line kept in $this->logged. */
    private function routes(Cronwatch $cw, string|false|null $token = null, ?string $basePath = '/cronwatch', ?string $origin = null, bool $trustProxy = false): Dashboard
    {
        $file = sys_get_temp_dir() . '/cronwatch-test-token-' . getmypid() . '-' . bin2hex(random_bytes(6));
        $this->tokenFiles[] = $file;
        return new Dashboard($cw, $token, $basePath, $origin, $trustProxy, function (string $line): void {
            $this->logged[] = $line;
        }, $file);
    }

    /** @return array{Cronwatch, Dashboard} */
    private function app(string|false|null $token = 'tok', ?string $basePath = '/cronwatch'): array
    {
        $cw = $this->client();
        return [$cw, $this->routes($cw, $token, $basePath)];
    }

    /** make(), on a store of its own, so a production environment gets no warning about the default one. */
    private function client(array $options = []): Cronwatch
    {
        return $this->make($options + ['store' => new MemoryStore()]);
    }

    private static function nothing(): \Closure
    {
        return fn () => null;
    }

    // ------------------------------------------------------------ routes.test.ts

    public function testEverythingNeedsTheToken(): void
    {
        [, $web] = $this->app();
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch')->status);
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch/api/jobs')->status);
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch/api/jobs', ['authorization' => 'Bearer wrong'])->status);
        $this->assertSame(200, self::send($web, 'GET', '/cronwatch/api/jobs', self::BEARER)->status);
    }

    public function testTheCheckEndpointAlsoAcceptsTheCronSecretNothingElseDoes(): void
    {
        $cw = $this->client(['cronSecret' => 'cron-s3cret']);
        $web = $this->routes($cw, 'tok');
        $withCron = ['authorization' => 'Bearer cron-s3cret'];
        $this->assertSame(200, self::send($web, 'GET', '/cronwatch/api/check', $withCron)->status);
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch/api/jobs', $withCron)->status);
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch/api/check?token=cron-s3cret')->status, 'only as a bearer header');
    }

    public function testTokenInTheQuerySetsACookieAndRedirectsToACleanUrl(): void
    {
        [, $web] = $this->app();
        $res = self::send($web, 'GET', '/cronwatch/?token=tok');
        $this->assertSame(303, $res->status);
        $this->assertSame('/cronwatch/', $res->header('location'));
        $cookie = (string) $res->header('set-cookie');
        $digest = hash('sha256', 'cronwatch-cookie:tok');
        $this->assertSame("cronwatch_token={$digest}", explode(';', $cookie)[0], 'a digest, not the token');
        $this->assertStringContainsString('; Path=/cronwatch; HttpOnly; SameSite=Lax', $cookie);
        $page = self::send($web, 'GET', '/cronwatch/', ['cookie' => "other=1; cronwatch_token={$digest}"]);
        $this->assertSame(200, $page->status);
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch/', ['cookie' => 'cronwatch_token=tok'])->status, 'the raw token is not a cookie');
        $this->assertStringContainsString('text/html', (string) $page->header('content-type'));
    }

    public function testTheSignInRedirectKeepsTheRestOfTheQueryAsUrlSearchParamsWritesIt(): void
    {
        [, $web] = $this->app();
        $res = self::send($web, 'GET', '/cronwatch/?a=1&token=tok&b=x+y%2Fz&c=%7E*&d');
        $this->assertSame('/cronwatch/?a=1&b=x+y%2Fz&c=%7E*&d=', $res->header('location'));
    }

    public function testDashboardAndJobPagesRenderAndTheJsonApiAnswers(): void
    {
        [$cw, $web] = $this->app();
        $job = $cw->job('nightly-report', ['schedule' => '0 2 * * *', 'description' => 'Builds the PDF']);
        $job->run(function (JobContext $ctx): void {
            $ctx->log('built');
            $this->clock->advance(2000);
        });
        $this->failing(fn () => $cw->run('broken', self::thrower('kaboom <script>')));

        $dash = self::send($web, 'GET', '/cronwatch', self::BEARER)->body;
        $this->assertStringContainsString('nightly-report', $dash);
        $this->assertStringContainsString('Builds the PDF', $dash);
        $this->assertStringContainsString('<p class="headline">2 jobs, <b>1 needing attention</b>.</p>', $dash);
        $this->assertStringContainsString('<div class="bad"><dt><i class="sq bad" aria-hidden="true"></i>failing</dt><dd>1</dd></div>', $dash);
        $this->assertMatchesRegularExpression('/<section class="sec" aria-label="Last 24 hours">[\s\S]*<figure class="timeline day">/', $dash);
        $this->assertStringContainsString('<form class="inline" method="post" action="/cronwatch/check"><button class="primary" type="submit">Run check now</button></form>', $dash);

        $page = self::send($web, 'GET', '/cronwatch/jobs/broken', self::BEARER);
        $this->assertSame(200, $page->status);
        $this->assertStringContainsString('kaboom &lt;script&gt;', $page->body, 'error text is escaped');
        $this->assertStringNotContainsString('<script>', $page->body);
        $this->assertStringContainsString('<h1 class="jobname">broken</h1>', $page->body);
        $this->assertStringContainsString('<details class="out error" open><summary>error</summary><pre>RuntimeException: kaboom &lt;script&gt;', $page->body);

        $this->assertCount(2, self::json(self::send($web, 'GET', '/cronwatch/api/jobs', self::BEARER))['jobs']);
        $one = self::json(self::send($web, 'GET', '/cronwatch/api/jobs/nightly-report?runs=5', self::BEARER));
        $this->assertSame('healthy', $one['job']['health']);
        $this->assertSame('built', $one['runs'][0]['output']);
        $this->assertSame(404, self::send($web, 'GET', '/cronwatch/api/jobs/missing', self::BEARER)->status);
        $this->assertSame(404, self::send($web, 'GET', '/cronwatch/jobs/missing', self::BEARER)->status);
        $this->assertSame(404, self::send($web, 'GET', '/cronwatch/nope', self::BEARER)->status);
    }

    public function testAHostsHeadReplacesThePagesAssetsAndTheAppShellItNoLongerNeeds(): void
    {
        $cw = $this->client();
        $cw->job('nightly-report', ['schedule' => '0 2 * * *']);
        $bases = [];
        $web = new Dashboard($cw, 'tok', '/cronwatch', head: function (string $base) use (&$bases): string {
            $bases[] = $base;
            return "<link rel=\"stylesheet\" href=\"/assets/dashboard.css\">\n";
        });
        $plain = $this->routes($cw, 'tok');
        foreach (['/cronwatch', '/cronwatch/jobs/nightly-report', '/cronwatch/nope'] as $path) {
            $page = self::send($web, 'GET', $path, self::BEARER)->body;
            $theirs = self::send($plain, 'GET', $path, self::BEARER)->body;
            $this->assertStringContainsString("<meta name=\"apple-mobile-web-app-status-bar-style\" content=\"default\">\n<link rel=\"stylesheet\" href=\"/assets/dashboard.css\">\n</head>", $page);
            $this->assertStringNotContainsString('<script', $page);
            $this->assertStringNotContainsString('<style', $page);
            $this->assertStringNotContainsString('manifest', $page);
            // Everything else is the SDK's page.
            $this->assertSame(
                (string) preg_replace('#<link rel="manifest"[\s\S]*</style>\n#', '', $theirs),
                str_replace("<link rel=\"stylesheet\" href=\"/assets/dashboard.css\">\n", '', $page),
            );
        }
        $this->assertSame(['/cronwatch', '/cronwatch', '/cronwatch'], $bases);
        $this->assertStringContainsString('<style>' . \Cronwatch\Web\Html::CSS . '</style>', self::send($plain, 'GET', '/cronwatch', self::BEARER)->body);
        foreach (['/manifest.webmanifest', '/app.js', '/sw.js', '/offline'] as $path) {
            $this->assertSame(200, self::send($plain, 'GET', "/cronwatch{$path}")->status);
            $this->assertSame(401, self::send($web, 'GET', "/cronwatch{$path}")->status, "{$path} is not served under a host's head");
            $this->assertSame(404, self::send($web, 'GET', "/cronwatch{$path}", self::BEARER)->status);
        }
        $icon = self::send($web, 'GET', '/cronwatch/icons/icon.svg');
        $this->assertSame(200, $icon->status);
        $this->assertSame('image/svg+xml', $icon->headers['content-type']);
    }

    public function testCheckSilenceUnsilenceAndForgetOverTheApi(): void
    {
        [$cw, $web] = $this->app();
        $cw->run('s', self::nothing());
        $post = fn (string $path, ?array $body = null) => self::send($web, 'POST', $path, self::JSON, $body === null ? null : json_encode($body));
        $check = self::json($post('/cronwatch/api/check'));
        $this->assertTrue($check['ok']);
        $this->assertCount(1, $check['jobs']);
        $this->assertGreaterThan(0, self::json($post('/cronwatch/api/jobs/s/silence', ['for' => '2h']))['job']['silencedUntil']);
        $this->assertSame('silenced', $cw->jobSummary('s')->health);
        $this->assertNull(self::json($post('/cronwatch/api/jobs/s/unsilence'))['job']['silencedUntil']);
        $this->assertSame(404, $post('/cronwatch/api/jobs/nope/silence', ['for' => '1h'])->status);
        $this->assertSame(200, self::send($web, 'DELETE', '/cronwatch/api/jobs/s', self::BEARER)->status);
        $this->assertNull($cw->jobSummary('s'));
    }

    public function testGetApiNamesTheLibraryBehindTheToken(): void
    {
        $cw = new Cronwatch(store: new MemoryStore(), alerts: [], cronSecret: 'cron', onError: fn () => null);
        $web = $this->routes($cw, 'tok');
        $answer = '{"ok":true,"library":"cronwatch/cronwatch","language":"php","version":"' . Cronwatch::VERSION . '","api":1}';
        foreach (['/cronwatch/api', '/cronwatch/api/'] as $path) {
            $res = self::send($web, 'GET', $path, self::BEARER);
            $this->assertSame([200, $answer, 'application/json; charset=utf-8'], [$res->status, $res->body, $res->headers['content-type']], $path);
        }
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch/api')->status);
        // The cron secret opens /api/check only.
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch/api', ['authorization' => 'Bearer cron'])->status);
        $post = self::send($web, 'POST', '/cronwatch/api', self::JSON, '{}');
        $this->assertSame([404, ['ok' => false, 'error' => 'Not found']], [$post->status, self::json($post)]);
    }

    public function testABodyOverAMebibyteIsRefusedWith413(): void
    {
        [$cw, $web] = $this->app();
        $cw->run('s', self::nothing());
        $big = json_encode(['for' => '2h', 'pad' => str_repeat('x', Request::MAX_BODY)]);
        $answer = self::send($web, 'POST', '/cronwatch/api/jobs/s/silence', self::JSON, $big);
        $this->assertSame([413, ['ok' => false, 'error' => 'Request body too large']], [$answer->status, self::json($answer)]);
        $this->assertNull($cw->store->getState('s')?->silencedUntil, 'not silenced');
        // Told by its Content-Length alone, before anything is read.
        $unread = new Request('POST', '/cronwatch/api/jobs/s/silence', '', self::BEARER + self::JSON + ['content-length' => '99999999999999999999'], fn () => throw new \LogicException('read'), 'http://app.test');
        $this->assertSame(413, $web->handle($unread)->status);
        $form = self::send($web, 'POST', '/cronwatch/jobs/s/silence', self::BEARER + self::FORM, 'for=4h&pad=' . str_repeat('x', Request::MAX_BODY));
        $this->assertSame(413, $form->status);
        // Nothing is read for a caller without the token.
        $stranger = new Request('POST', '/cronwatch/api/jobs/s/silence', '', ['content-type' => 'application/json'], fn () => throw new \LogicException('read'), 'http://app.test');
        $this->assertSame(401, $web->handle($stranger)->status);
        $this->assertSame(200, self::send($web, 'POST', '/cronwatch/api/jobs/s/silence', self::JSON, json_encode(['for' => '2h']))->status, 'a body of a few bytes is fine');
    }

    public function testDashboardFormsPostAndRedirectBack(): void
    {
        [$cw, $web] = $this->app();
        $cw->run('f', self::nothing());
        $form = self::send($web, 'POST', '/cronwatch/jobs/f/silence', self::BEARER + self::FORM + ['referer' => 'http://app.test/cronwatch/jobs/f'], 'for=4h');
        $this->assertSame(303, $form->status);
        $this->assertSame('http://app.test/cronwatch/jobs/f', $form->header('location'));
        $this->assertSame('silenced', $cw->jobSummary('f')->health);
        $elsewhere = self::send($web, 'POST', '/cronwatch/jobs/f/unsilence', self::BEARER + ['referer' => 'https://evil.example/phish']);
        $this->assertSame('/cronwatch/', $elsewhere->header('location'), 'a foreign referer is not followed');
    }

    public function testAMultipartFormIsReadLikeFormData(): void
    {
        [$cw, $web] = $this->app();
        $cw->run('f', self::nothing());
        $body = "--cw\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\n2h\r\n"
            . "--cw\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--cw--\r\n";
        $res = self::send($web, 'POST', '/cronwatch/jobs/f/silence', self::BEARER + ['content-type' => 'multipart/form-data; boundary=cw'], $body);
        $this->assertSame(303, $res->status);
        $this->assertSame(($this->clock)() + 2 * self::HOUR, $cw->jobSummary('f')->silencedUntil);
        // A form PHP parsed itself ($_POST), as a server hands it over.
        $parsed = new Request('POST', '/cronwatch/jobs/f/silence', '', self::BEARER + ['content-type' => 'multipart/form-data; boundary=x'], '', 'http://app.test', null, ['for' => '4h']);
        $this->assertSame(303, $web->handle($parsed)->status);
        $this->assertSame(($this->clock)() + 4 * self::HOUR, $cw->jobSummary('f')->silencedUntil);
    }

    /** @return array<string, array{string|null}> */
    public static function notDevelopment(): array
    {
        return ['unset' => [null], 'production' => ['production'], 'staging' => ['staging']];
    }

    #[DataProvider('notDevelopment')]
    public function testWithoutATokenOutsideDevelopmentTheRoutesAreLocked(?string $env): void
    {
        if ($env !== null) {
            putenv("CRONWATCH_ENV={$env}");
        }
        $web = $this->routes($this->client());
        $this->assertSame(503, self::send($web, 'GET', '/cronwatch/api/jobs')->status);
        $locked = self::send($web, 'GET', '/cronwatch');
        $this->assertSame(503, $locked->status);
        $this->assertStringContainsString('CronWatch routes are locked', $locked->body);
    }

    /** @return array<string, array{string}> */
    public static function development(): array
    {
        return ['development' => ['development'], 'test' => ['test'], 'local' => ['local']];
    }

    #[DataProvider('development')]
    public function testWithoutATokenInDevelopmentAMadeUpTokenIsLoggedOnceKeptAndRequired(string $env): void
    {
        putenv("CRONWATCH_ENV={$env}");
        $web = $this->routes($this->client(), null, '/cronwatch/');
        // Every request is refused without the token, whatever it claims about where it came from.
        foreach ([['http://localhost:3000/cronwatch/api/jobs', []], ['http://localhost:3000/cronwatch/api/jobs', ['x-forwarded-for' => '127.0.0.1']],
            ['http://127.0.0.1:3000/cronwatch/', []], ['http://192.168.1.20:3000/cronwatch/api/jobs', []]] as [$url, $headers]) {
            $this->assertSame(401, self::send($web, 'GET', $url, $headers)->status, $url);
        }
        $this->assertCount(1, $this->logged, 'announced once, when the token is made');
        $this->assertMatchesRegularExpression('#^\[cronwatch\] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard\. Sign in: http://localhost:3000/cronwatch/\?token=([A-Za-z0-9_-]{43})$#D', $this->logged[0]);
        $token = substr($this->logged[0], -43);

        $page = self::send($web, 'GET', 'http://localhost:3000/cronwatch/');
        $this->assertSame(401, $page->status);
        $this->assertStringContainsString('sign-in link is in the server log', $page->body);
        $this->assertStringContainsString('in the server log', self::json(self::send($web, 'GET', 'http://localhost:3000/cronwatch/api/jobs'))['error']);

        $signIn = self::send($web, 'GET', "http://localhost:3000/cronwatch/?token={$token}");
        $this->assertSame(303, $signIn->status);
        $this->assertSame('/cronwatch/', $signIn->header('location'));
        $cookie = explode(';', (string) $signIn->header('set-cookie'))[0];
        $this->assertSame(200, self::send($web, 'GET', 'http://localhost:3000/cronwatch/', ['cookie' => $cookie])->status);
        $this->assertSame(200, self::send($web, 'GET', 'http://localhost:3000/cronwatch/api/jobs', ['authorization' => "Bearer {$token}"])->status);

        // The next PHP request is a new dashboard: it reads the same token from its file and says nothing.
        $again = new Dashboard($this->client(), null, '/cronwatch', null, false, function (string $line): void {
            $this->logged[] = $line;
        }, end($this->tokenFiles));
        $this->assertSame(200, self::send($again, 'GET', 'http://localhost:3000/cronwatch/api/jobs', ['authorization' => "Bearer {$token}"])->status);
        $this->assertCount(1, $this->logged);
        $this->assertSame('600', substr(sprintf('%o', fileperms(end($this->tokenFiles))), -3), 'only the server can read it');

        $other = $this->routes($this->client(), null, '/');
        self::send($other, 'GET', 'https://dev.example:8443/api/jobs');
        $this->assertMatchesRegularExpression('#Sign in: /\?token=([A-Za-z0-9_-]{43}) on this server \(the first request\'s host is not local, so the link leaves it out\)$#D', $this->logged[1], 'no host that is not local, and a root mount');
        preg_match('#token=([A-Za-z0-9_-]{43})#', $this->logged[1], $other);
        $this->assertNotSame($token, $other[1], 'another dashboard makes its own');
    }

    public function testADevelopmentTokenFileSomeoneElseCouldWriteIsNotTrusted(): void
    {
        putenv('CRONWATCH_ENV=development');
        $planted = str_repeat('A', 43);
        // A token planted by another user of the temporary directory: readable by others, so not this server's.
        $web = $this->routes($this->client());
        $file = end($this->tokenFiles);
        file_put_contents($file, $planted);
        chmod($file, 0644);
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch/api/jobs', ['authorization' => "Bearer {$planted}"])->status);
        $this->assertCount(1, $this->logged, 'a token of its own made and announced');
        // A link in its place is not followed either.
        $link = sys_get_temp_dir() . '/cronwatch-test-link-' . getmypid() . '-' . bin2hex(random_bytes(4));
        $target = "{$link}-target";
        file_put_contents($target, $planted);
        chmod($target, 0600);
        symlink($target, $link);
        try {
            $linked = new Dashboard($this->client(), null, '/cronwatch', null, false, function (string $line): void {
                $this->logged[] = $line;
            }, $link);
            $this->assertSame(401, self::send($linked, 'GET', '/cronwatch/api/jobs', ['authorization' => "Bearer {$planted}"])->status);
        } finally {
            @unlink($link);
            @unlink($target);
        }
    }

    public function testTheDefaultDevelopmentTokenFileIsInADirectoryOfTheUsersOwn(): void
    {
        putenv('CRONWATCH_ENV=development');
        $base = '/cronwatch-default-' . bin2hex(random_bytes(4));
        $web = new Dashboard($this->client(), null, $base, null, false, function (string $line): void {
            $this->logged[] = $line;
        });
        $this->assertSame(401, self::send($web, 'GET', "http://localhost{$base}/api/jobs")->status);
        $uid = function_exists('posix_geteuid') ? posix_geteuid() : getmyuid();
        $dir = sys_get_temp_dir() . "/cronwatch-{$uid}";
        $this->assertDirectoryExists($dir);
        $this->assertSame(0, fileperms($dir) & 0077, 'nobody else may list or write it');
        $token = substr($this->logged[0], -43);
        $again = new Dashboard($this->client(), null, $base, null, false, fn () => null);
        $this->assertSame(200, self::send($again, 'GET', "http://localhost{$base}/api/jobs", ['authorization' => "Bearer {$token}"])->status, 'kept for the next request');
        foreach (glob("{$dir}/dev-token-*") ?: [] as $file) {
            if (trim((string) file_get_contents($file)) === $token) {
                unlink($file);
            }
        }
    }

    public function testAFrameworksEnvironmentCountsWhenNoVariableNamesOne(): void
    {
        \Cronwatch\Env::setFallback(fn () => ' Local ');
        try {
            $this->assertTrue(\Cronwatch\Env::isDevelopment());
            self::send($this->routes($this->client()), 'GET', '/cronwatch/api/jobs');
            $this->assertCount(1, $this->logged, 'a development token, as the framework says development');
            putenv('APP_ENV=production');
            $this->assertTrue(\Cronwatch\Env::isProduction(), 'a variable comes first');
            \Cronwatch\Env::setFallback(fn () => throw new \RuntimeException('not booted'));
            putenv('APP_ENV');
            $this->assertNull(\Cronwatch\Env::environment(), 'a fallback that throws names nothing');
        } finally {
            \Cronwatch\Env::setFallback(null);
        }
    }

    public function testAnEmptyTokenCountsAsUnsetFalseOptsOutExplicitly(): void
    {
        putenv('CRONWATCH_ENV=production');
        putenv('CRONWATCH_TOKEN=');
        $this->assertSame(503, self::send($this->routes($this->client()), 'GET', '/cronwatch/api/jobs')->status);
        $this->assertSame(503, self::send($this->routes($this->client(), ''), 'GET', '/cronwatch/api/jobs')->status);
        $this->assertSame(200, self::send($this->routes($this->client(), false), 'GET', '/cronwatch/api/jobs')->status, 'token: false serves open');

        putenv('CRONWATCH_ENV=development');
        putenv('CRONWATCH_TOKEN');
        $this->assertSame(200, self::send($this->routes($this->client(), false), 'GET', '/cronwatch/api/jobs')->status, 'token: false serves open in development too');
        $this->assertSame([], $this->logged, 'and makes no token');

        putenv('CRONWATCH_TOKEN=envtok');
        $this->assertSame(401, self::send($this->routes($this->client()), 'GET', '/cronwatch/api/jobs')->status, 'a configured token is used in development');
        $this->assertSame([], $this->logged);

        putenv('CRONWATCH_ENV=production');
        $web = $this->routes($this->client(), '');
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch/api/jobs')->status);
        $this->assertSame(200, self::send($web, 'GET', '/cronwatch/api/jobs', ['authorization' => 'Bearer envtok'])->status);
    }

    // ------------------------------------------------------------ routes-security.test.ts

    /** @return array<string, array{array<string, string>}> */
    public static function crossSiteHeaders(): array
    {
        return [
            'foreign origin' => [['origin' => 'https://evil.example']],
            'null origin' => [['origin' => 'null']],
            'cross-site' => [['sec-fetch-site' => 'cross-site']],
            'same-site' => [['sec-fetch-site' => 'same-site']],
            'own origin, cross-site' => [['origin' => 'http://app.test', 'sec-fetch-site' => 'cross-site']],
        ];
    }

    #[DataProvider('crossSiteHeaders')]
    public function testCrossSiteWritesAreRefusedWhateverTheCredentials(array $headers): void
    {
        [$cw, $web] = $this->app();
        $cw->run('x', self::nothing());
        $this->assertSame(403, self::send($web, 'POST', '/cronwatch/jobs/x/silence', self::cookie() + self::FORM + $headers, 'for=1h')->status);
        $this->assertSame(403, self::send($web, 'POST', '/cronwatch/api/check', self::BEARER + $headers)->status);
        $this->assertSame(403, self::send($web, 'DELETE', '/cronwatch/api/jobs/x', self::cookie() + $headers)->status);
        $this->assertNotNull($cw->jobSummary('x'));
        $this->assertNull($cw->jobSummary('x')->silencedUntil);
    }

    public function testSameOriginFormsAndHeaderLessApiClientsStillWrite(): void
    {
        [$cw, $web] = $this->app();
        $cw->run('x', self::nothing());
        $same = ['origin' => 'http://app.test', 'sec-fetch-site' => 'same-origin', 'referer' => 'http://app.test/cronwatch/jobs/x'];
        $this->assertSame(303, self::send($web, 'POST', '/cronwatch/check', self::cookie() + $same)->status, 'the dashboard\'s Run check now button');
        $silence = self::send($web, 'POST', '/cronwatch/jobs/x/silence', self::cookie() + $same + self::FORM, 'for=4h');
        $this->assertSame(303, $silence->status);
        $this->assertSame('http://app.test/cronwatch/jobs/x', $silence->header('location'));
        $this->assertSame(200, self::send($web, 'POST', '/cronwatch/api/jobs/x/unsilence', self::BEARER)->status);
        $this->assertSame(200, self::send($web, 'POST', '/cronwatch/api/check', self::BEARER + ['sec-fetch-site' => 'none'])->status);
    }

    public function testGetApiCheckRunsOnlyForABearerCookiesMustPost(): void
    {
        [, $web] = $this->app();
        $viaCookie = self::send($web, 'GET', '/cronwatch/api/check', self::cookie());
        $this->assertSame(405, $viaCookie->status);
        $this->assertSame('POST', $viaCookie->header('allow'));
        $this->assertSame(200, self::send($web, 'POST', '/cronwatch/api/check', self::cookie())->status);
        $this->assertSame(200, self::send($web, 'GET', '/cronwatch/api/check', self::BEARER)->status);
    }

    public function testTokenInTheQueryIsOnlyAcceptedOnAnHtmlGet(): void
    {
        [$cw, $web] = $this->app();
        $cw->run('x', self::nothing());
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch/api/jobs?token=tok')->status);
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch/api/jobs/x?token=tok')->status);
        $this->assertSame(401, self::send($web, 'POST', '/cronwatch/api/check?token=tok')->status);
        $this->assertSame(401, self::send($web, 'POST', '/cronwatch/check?token=tok')->status);
        $this->assertSame(401, self::send($web, 'POST', '/cronwatch/jobs/x/forget?token=tok')->status);
        $this->assertNotNull($cw->jobSummary('x'));
        $this->assertSame(303, self::send($web, 'GET', '/cronwatch/jobs/x?token=tok')->status);
    }

    public function testMalformedCookiesAndPathsAreAnsweredNotThrown(): void
    {
        [, $web] = $this->app();
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch/', ['cookie' => 'cronwatch_token=%E0%A4%A'])->status);
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch/api/jobs', ['cookie' => 'cronwatch_token=%'])->status);
        $this->assertSame(400, self::send($web, 'GET', '/cronwatch/jobs/%E0%A4%A', self::BEARER)->status);
        $api = self::send($web, 'GET', '/cronwatch/api/jobs/%zz', self::BEARER);
        $this->assertSame(400, $api->status);
        $this->assertFalse(self::json($api)['ok']);
        $this->assertSame(400, self::send($web, 'POST', '/cronwatch/api/jobs/%zz/silence', self::BEARER)->status);
    }

    /** @return array<string, array{string, int}> */
    public static function runsLimits(): array
    {
        return ['0' => ['0', 1], '-5' => ['-5', 1], '2.7' => ['2.7', 2], 'abc' => ['abc', 3], 'empty' => ['', 3], '1e9' => ['1e9', 3],
            'Infinity' => ['Infinity', 3], '0x2' => ['0x2', 2], 'spaces' => ['%202%20', 2], '1_0' => ['1_0', 3]];
    }

    #[DataProvider('runsLimits')]
    public function testRunsIsClampedToAWholeNumberInRange(string $runs, int $count): void
    {
        [$cw, $web] = $this->app();
        for ($i = 0; $i < 3; $i++) {
            $cw->run('r', self::nothing());
        }
        $this->assertCount($count, self::json(self::send($web, 'GET', "/cronwatch/api/jobs/r?runs={$runs}", self::BEARER))['runs']);
    }

    public function testAnUnexpectedErrorIsAGeneric500ReportedThroughOnError(): void
    {
        $store = new DelegatingStore(new MemoryStore());
        $cw = $this->client(['store' => $store]);
        $web = $this->routes($cw, 'tok');
        $store->hooks['listJobs'] = fn () => throw new \RuntimeException('secret connection string');
        $api = self::send($web, 'GET', '/cronwatch/api/jobs', self::BEARER);
        $this->assertSame(500, $api->status);
        $this->assertStringNotContainsString('secret', $api->body);
        $this->assertSame(['ok' => false, 'error' => 'Internal error'], self::json($api));
        $page = self::send($web, 'GET', '/cronwatch/', self::BEARER);
        $this->assertSame(500, $page->status);
        $this->assertStringContainsString('text/html', (string) $page->header('content-type'));
        $this->assertStringNotContainsString('secret', $page->body);
        $this->assertSame(['routes', 'routes'], $this->wheres());
        $this->assertStringContainsString('secret connection string', $this->messages()[0]);
    }

    public function testAThrowingOnErrorStillYieldsA500(): void
    {
        $store = new DelegatingStore(new MemoryStore());
        $cw = $this->client(['store' => $store, 'onError' => fn () => throw new \RuntimeException('logger down')]);
        $store->hooks['listJobs'] = fn () => throw new \RuntimeException('boom');
        $this->assertSame(500, self::send($this->routes($cw, 'tok'), 'GET', '/cronwatch/api/jobs', self::BEARER)->status);
    }

    public function testSilenceDurationsStringsAreValidatedNumbersAreMilliseconds(): void
    {
        [$cw, $web] = $this->app();
        $cw->run('s', self::nothing());
        $silence = fn (array $body) => self::send($web, 'POST', '/cronwatch/api/jobs/s/silence', self::JSON, json_encode($body, JSON_FORCE_OBJECT));
        foreach (['forever', '2 hours', '', '-5', '1h then some'] as $bad) {
            $res = $silence(['for' => $bad]);
            $this->assertSame(400, $res->status, $bad);
            $this->assertFalse(self::json($res)['ok']);
            $this->assertStringContainsString('silence duration', self::json($res)['error'], $bad);
        }
        $this->assertNull($cw->jobSummary('s')->silencedUntil, 'a bad duration silences nothing');
        $until = fn (array $body) => self::json($silence($body))['job']['silencedUntil'] - ($this->clock)();
        $this->assertSame(7_200_000, $until(['for' => 7_200_000]));
        $this->assertSame(60_000, $until(['for' => '60000']));
        $this->assertSame(90 * 60_000, $until(['for' => '90m']));
        $this->assertSame(self::HOUR, $until([]));
        $this->assertSame(400, self::send($web, 'POST', '/cronwatch/api/jobs/s/silence?for=forever', self::BEARER)->status);
    }

    public function testTheSilenceFormShowsAnErrorForABadDurationAnd404sAMissingJob(): void
    {
        [$cw, $web] = $this->app();
        $cw->run('s', self::nothing());
        $form = self::cookie() + self::FORM;
        $bad = self::send($web, 'POST', '/cronwatch/jobs/s/silence', $form, 'for=forever');
        $this->assertSame(400, $bad->status);
        $this->assertStringContainsString('text/html', (string) $bad->header('content-type'));
        $this->assertStringContainsString('silence duration &quot;forever&quot;', $bad->body);
        $this->assertNull($cw->jobSummary('s')->silencedUntil);
        $this->assertSame(404, self::send($web, 'POST', '/cronwatch/jobs/ghost/silence', $form, 'for=1h')->status);
        $this->assertSame(404, self::send($web, 'POST', '/cronwatch/jobs/ghost/unsilence', $form)->status);
        $this->assertSame(404, self::send($web, 'POST', '/cronwatch/jobs/s/explode', $form)->status);
    }

    public function testPagesCarryAStrictCspAndSecurityHeadersAndNeedNoScriptOfTheirOwn(): void
    {
        [$cw, $web] = $this->app();
        $cw->run('h', self::nothing());
        foreach (['/cronwatch/', '/cronwatch/jobs/h', '/cronwatch/nope'] as $path) {
            $res = self::send($web, 'GET', $path, self::BEARER);
            $this->assertSame(self::CSP, $res->header('content-security-policy'));
            $this->assertSame('DENY', $res->header('x-frame-options'));
            $this->assertSame('nosniff', $res->header('x-content-type-options'));
            $this->assertSame('same-origin', $res->header('referrer-policy'));
            $this->assertSame('no-store', $res->header('cache-control'));
            preg_match_all('/<script[^>]*>[^<]*<\/script>/i', $res->body, $scripts);
            $this->assertSame(['<script src="/cronwatch/app.js" defer></script>'], $scripts[0]);
            $this->assertSame(1, preg_match_all('/<script/i', $res->body));
            $this->assertDoesNotMatchRegularExpression('/\son[a-z]+=/i', $res->body, 'no inline event handlers');
        }
        $this->assertStringContainsString('<details class="confirm"><summary>Forget</summary><form', self::send($web, 'GET', '/cronwatch/jobs/h', self::BEARER)->body);
        $api = self::send($web, 'GET', '/cronwatch/api/jobs', self::BEARER);
        $this->assertSame('nosniff', $api->header('x-content-type-options'));
        $this->assertSame('no-store', $api->header('cache-control'));
    }

    public function testMarkupInDefinitionsOutputAndMetricsStaysEscapedOnEveryPage(): void
    {
        [$cw, $web] = $this->app();
        $job = $cw->job('m', ['schedule' => '0 2 * * *', 'description' => '<img src=x>', 'tags' => ['<t>'], 'expect' => '<e>']);
        $job->run(function (JobContext $ctx): void {
            $ctx->log('<o>');
            $ctx->metric('<k>', 1);
        });
        foreach (['/cronwatch/', '/cronwatch/jobs/m', '/cronwatch/jobs/%3Cx%3E'] as $path) {
            $this->assertDoesNotMatchRegularExpression('/<img|<t>|<e>|<o>|<k>|<x>/', self::send($web, 'GET', $path, self::BEARER)->body, $path);
        }
    }

    public function testAStoredMetricThatIsNoFiniteNumberIsLeftOffTheJobPage(): void
    {
        [$cw, $web] = $this->app();
        $cw->job('odd');
        $cw->store->insertRun(Run::fromJson([
            'id' => 'o1', 'job' => 'odd', 'status' => 'ok', 'startedAt' => self::T0 - self::MIN, 'finishedAt' => self::T0, 'durationMs' => self::MIN,
            'error' => null, 'output' => null, 'metrics' => ['rows' => null, 'label' => 'abc', 'cost' => 1.25, 'n' => 3], 'trigger' => 'run',
        ]));
        $res = self::send($web, 'GET', '/cronwatch/jobs/odd', self::BEARER);
        $this->assertSame(200, $res->status);
        $this->assertStringContainsString('<span class="metrics"><span><span class="k">cost</span> 1.2500</span><span><span class="k">n</span> 3</span></span>', $res->body);
        $this->assertStringNotContainsString('>rows<', $res->body);
        $this->assertStringNotContainsString('>label<', $res->body);
    }

    public function testWithoutATokenInDevelopmentNothingARequestSaysAboutItselfLetsItIn(): void
    {
        putenv('CRONWATCH_ENV=development');
        $web = $this->routes($this->client());
        $local = 'http://localhost:3000/cronwatch/api/jobs';
        foreach ([[], ['x-forwarded-host' => 'localhost:3000', 'x-forwarded-for' => '::ffff:127.0.0.1', 'x-forwarded-proto' => 'http'],
            ['x-forwarded-for' => '::1'], ['forwarded' => 'for="[::1]:51234";host=localhost;proto=http'], ['x-real-ip' => '127.0.0.1']] as $headers) {
            $res = self::send($web, 'GET', $local, $headers);
            $this->assertSame(401, $res->status);
            $this->assertFalse(self::json($res)['ok']);
        }
        $this->assertSame(401, self::send($web, 'POST', 'http://localhost:3000/cronwatch/api/check')->status);
    }

    // ------------------------------------------------------------ routes-origin.test.ts

    private const INTERNAL = 'http://10.0.0.5:8080';

    public function testByDefaultTheRequestUrlsOriginIsTheOrigin(): void
    {
        [$cw, $web] = $this->app();
        $cw->run('x', self::nothing());
        $this->assertSame(403, self::send($web, 'POST', self::INTERNAL . '/cronwatch/jobs/x/silence', self::cookie() + self::FORM + ['origin' => 'https://app.example.com'], 'for=1h')->status);
        $this->assertNull($cw->jobSummary('x')->silencedUntil);
        $this->assertSame(303, self::send($web, 'POST', self::INTERNAL . '/cronwatch/jobs/x/silence', self::cookie() + self::FORM + ['origin' => self::INTERNAL], 'for=1h')->status);
        $this->assertStringNotContainsString('Secure', (string) self::send($web, 'GET', self::INTERNAL . '/cronwatch/?token=tok')->header('set-cookie'));
    }

    public function testOriginReplacesTheRequestUrlsOriginForWritesSignInAndRedirects(): void
    {
        $cw = $this->client();
        $web = $this->routes($cw, 'tok', '/cronwatch', 'https://app.example.com/ignored/path');
        $cw->run('x', self::nothing());
        $this->assertSame(403, self::send($web, 'POST', self::INTERNAL . '/cronwatch/jobs/x/silence', self::cookie() + self::FORM + ['origin' => self::INTERNAL], 'for=1h')->status, 'the internal origin is now foreign');
        $referer = 'https://app.example.com/cronwatch/jobs/x';
        $ok = self::send($web, 'POST', self::INTERNAL . '/cronwatch/jobs/x/silence', self::cookie() + self::FORM + ['origin' => 'https://app.example.com', 'referer' => $referer], 'for=2h');
        $this->assertSame(303, $ok->status);
        $this->assertSame($referer, $ok->header('location'), 'the Referer on the public origin is followed back');
        $this->assertSame(($this->clock)() + 2 * self::HOUR, $cw->jobSummary('x')->silencedUntil);
        $signIn = self::send($web, 'GET', self::INTERNAL . '/cronwatch/jobs/x?token=tok');
        $this->assertSame('/cronwatch/jobs/x', $signIn->header('location'));
        $this->assertStringEndsWith('; Secure', (string) $signIn->header('set-cookie'), 'the public origin is https, so the cookie is Secure');
    }

    public function testOriginTakesPrecedenceOverTrustProxyAndForwardedHeaders(): void
    {
        $cw = $this->client();
        $web = $this->routes($cw, 'tok', '/cronwatch', 'https://app.example.com', true);
        $cw->run('x', self::nothing());
        $forwarded = ['x-forwarded-proto' => 'https', 'x-forwarded-host' => 'other.example'];
        $this->assertSame(403, self::send($web, 'POST', self::INTERNAL . '/cronwatch/check', self::cookie() + $forwarded + ['origin' => 'https://other.example'])->status);
        $this->assertSame(303, self::send($web, 'POST', self::INTERNAL . '/cronwatch/check', self::cookie() + $forwarded + ['origin' => 'https://app.example.com'])->status);
    }

    public function testAnOriginThatIsNotAnHttpOrHttpsUrlFailsWhenTheRoutesAreMade(): void
    {
        $cw = $this->client();
        foreach (['app.example.com' => 'routes: origin must be an absolute URL such as "https://app.example.com", got "app.example.com"',
            'ftp://app.example.com' => 'routes: origin must be http or https, got "ftp://app.example.com"'] as $origin => $message) {
            try {
                $cw->routes(token: 'tok', origin: $origin);
                $this->fail("{$origin} was taken");
            } catch (\InvalidArgumentException $error) {
                $this->assertSame($message, $error->getMessage());
            }
        }
        $cw->routes(token: 'tok', origin: '');
        $cw->routes(token: 'tok', origin: null);
    }

    /** What `new URL(value).origin` gives for each, in Node 24. @return array<string, array{string, string}> */
    public static function origins(): array
    {
        $cases = [
            ['https://App.Example.com/cronwatch?x=1#y', 'https://app.example.com'],
            ['HTTPS://app.example.com:443/', 'https://app.example.com'],
            ['http://app.example.com:80', 'http://app.example.com'],
            ['http://localhost:3000/', 'http://localhost:3000'],
            ['https://app.example.com:8443', 'https://app.example.com:8443'],
            [' https://app.example.com ', 'https://app.example.com'],
            ["\thttps://a.example\n", 'https://a.example'],
            ["https://app.exa\tmple.com", 'https://app.example.com'],
            ['https://APP.example.com.', 'https://app.example.com.'],
            ['https://user:pw@app.example.com', 'https://app.example.com'],
            ['https://app.example.com:', 'https://app.example.com'],
            ['https:app.example.com', 'https://app.example.com'],
            ['https:/app.example.com', 'https://app.example.com'],
            ['https:\\\\app.example.com', 'https://app.example.com'],
            ['https://[::1]:8080', 'https://[::1]:8080'],
            ['https://[0:0::1]', 'https://[::1]'],
            ['https://127.1', 'https://127.0.0.1'],
            ['https://0x7f.1', 'https://127.0.0.1'],
            ['https://app.example.com:0080', 'https://app.example.com:80'],
            ['https://app.example.com:0', 'https://app.example.com:0'],
            ['https://a_b.example.com', 'https://a_b.example.com'],
            ['https://%61pp.example', 'https://app.example'],
            ['https://xn--bcher-kva.example', 'https://xn--bcher-kva.example'],
            ["https://B\u{fc}cher.example", 'https://xn--bcher-kva.example'],
            ['https://65535.example:65535', 'https://65535.example:65535'],
        ];
        return array_combine(array_map(fn ($c) => json_encode($c[0]), $cases), $cases);
    }

    #[DataProvider('origins')]
    public function testTheOriginIsReadAsTheUrlParserReadsIt(string $given, string $expected): void
    {
        $this->assertSame($expected, \Cronwatch\Web\Origin::parse($given));
    }

    /** @return array<string, array{string}> */
    public static function badOrigins(): array
    {
        $cases = ['https://app.example.com:65536', 'https://app.example.com:99999999999', 'https://ex ample.com', 'https://app.example.com:8x', 'https://[::1',
            'https://[nope]', 'https://[::1%25eth0]', 'https://256.1.1.1', 'https://1.2.3.4.5', 'https://09.1.1.1', 'https://%zz.example', 'https://%ff.example',
            'http://', 'https:', 'https://@', 'https://a<b'];
        return array_combine($cases, array_map(fn ($c) => [$c], $cases));
    }

    #[DataProvider('badOrigins')]
    public function testAnOriginWithABadHostOrPortThrows(string $given): void
    {
        $this->expectException(\InvalidArgumentException::class);
        $this->expectExceptionMessageMatches('/^routes: origin must be an absolute URL/');
        \Cronwatch\Web\Origin::parse($given);
    }

    public function testTrustProxyTakesTheOriginFromTheFirstForwardedProtoAndHost(): void
    {
        $cw = $this->client();
        $web = $this->routes($cw, 'tok', '/cronwatch', null, true);
        $cw->run('x', self::nothing());
        $forwarded = ['x-forwarded-proto' => 'https, http', 'x-forwarded-host' => 'app.example.com, 10.0.0.5:8080'];
        $this->assertSame(403, self::send($web, 'POST', self::INTERNAL . '/cronwatch/jobs/x/silence', self::cookie() + self::FORM + $forwarded + ['origin' => self::INTERNAL], 'for=1h')->status);
        $this->assertSame(303, self::send($web, 'POST', self::INTERNAL . '/cronwatch/jobs/x/silence', self::cookie() + self::FORM + $forwarded + ['origin' => 'https://app.example.com'], 'for=1h')->status);
        $this->assertStringEndsWith('; Secure', (string) self::send($web, 'GET', self::INTERNAL . '/cronwatch/?token=tok', $forwarded)->header('set-cookie'));
        // Only the scheme forwarded: the host stays the request's.
        $this->assertSame(303, self::send($web, 'POST', self::INTERNAL . '/cronwatch/check', self::cookie() + ['x-forwarded-proto' => 'https', 'origin' => 'https://10.0.0.5:8080'])->status);
        // Neither forwarded: the request URL's origin, as without trustProxy.
        $this->assertSame(303, self::send($web, 'POST', self::INTERNAL . '/cronwatch/check', self::cookie() + ['origin' => self::INTERNAL])->status);
        foreach ([[['x-forwarded-proto' => 'javascript', 'x-forwarded-host' => 'evil.example'], 'javascript://evil.example'],
            [['x-forwarded-proto' => 'https', 'x-forwarded-host' => 'evil.example/path'], 'https://evil.example'],
            [['x-forwarded-proto' => 'https', 'x-forwarded-host' => 'user@evil.example'], 'https://evil.example']] as [$headers, $origin]) {
            $this->assertSame(403, self::send($web, 'POST', self::INTERNAL . '/cronwatch/check', self::cookie() + $headers + ['origin' => $origin])->status, $origin);
            $this->assertSame(303, self::send($web, 'POST', self::INTERNAL . '/cronwatch/check', self::cookie() + $headers + ['origin' => self::INTERNAL])->status, $origin);
        }
    }

    public function testWithoutTrustProxyASpoofedForwardedHostOrProtoChangesNothing(): void
    {
        [$cw, $web] = $this->app();
        $cw->run('x', self::nothing());
        $spoofed = ['x-forwarded-host' => 'evil.example', 'x-forwarded-proto' => 'https'];
        $this->assertSame(403, self::send($web, 'POST', '/cronwatch/jobs/x/silence', self::cookie() + self::FORM + $spoofed + ['origin' => 'https://evil.example'], 'for=1h')->status);
        $back = self::send($web, 'POST', '/cronwatch/check', self::cookie() + $spoofed + ['origin' => 'http://app.test', 'referer' => 'https://evil.example/cronwatch/jobs/x']);
        $this->assertSame(303, $back->status);
        $this->assertSame('/cronwatch/', $back->header('location'), 'a Referer on the spoofed origin is not followed');
        $this->assertStringNotContainsString('Secure', (string) self::send($web, 'GET', '/cronwatch/?token=tok', $spoofed)->header('set-cookie'));
    }

    public function testAMixedCaseHostMatchesTheBrowsersLowercaseOrigin(): void
    {
        [$cw, $web] = $this->app();
        $cw->run('x', self::nothing());
        $this->assertSame(303, self::send($web, 'POST', 'http://App.Example.com/cronwatch/check', self::cookie() + ['origin' => 'http://app.example.com'])->status);
    }

    public function testTheDevelopmentSignInLineUsesThePublicOriginWhenSetOrLoopbackAndOtherwiseLeavesTheHostOut(): void
    {
        putenv('CRONWATCH_ENV=development');
        $spoofed = ['x-forwarded-proto' => 'https', 'x-forwarded-host' => 'attacker.example'];
        $cases = [
            [['/cronwatch', 'https://app.example.com', false], self::INTERNAL . '/cronwatch/', []],
            [['/cronwatch', 'https://app.example.com', true], self::INTERNAL . '/cronwatch/', $spoofed],
            [['/cronwatch', null, false], 'http://localhost:3000/cronwatch/', []],
            [['/cronwatch', null, false], 'http://app.localhost:3000/cronwatch/', []],
            [['/cronwatch', null, false], 'http://127.0.0.1:3000/cronwatch/', []],
            [['/cronwatch', null, false], 'http://127.8.9.10/cronwatch/', []],
            [['/cronwatch', null, false], 'http://[::1]:3000/cronwatch/', []],
            [['/cronwatch', null, true], self::INTERNAL . '/cronwatch/', ['x-forwarded-host' => 'localhost:5173']],
            [['/cronwatch', null, false], self::INTERNAL . '/cronwatch/', []],
            [['/cronwatch', null, false], 'https://app.example.com/cronwatch/', []],
            [['/cronwatch', null, true], 'http://localhost:3000/cronwatch/', $spoofed],
            [['/cronwatch', null, false], 'http://localhost.example/cronwatch/', []],
            [['/cronwatch', null, false], 'http://128.0.0.1/cronwatch/', []],
            [['/', null, false], 'http://attacker.example/', []],
            [['/cronwatch', null, true], self::INTERNAL . '/cronwatch/', ['x-forwarded-host' => 'localhost:1@evil.example']],
            [['/cronwatch', null, true], self::INTERNAL . '/cronwatch/', ['x-forwarded-host' => 'evil.example/.localhost']],
        ];
        foreach ($cases as [[$basePath, $origin, $trustProxy], $url, $headers]) {
            self::send($this->routes($this->client(), null, $basePath, $origin, $trustProxy), 'GET', $url, $headers);
        }
        // PHP passes a Host header through as sent: it is read as a URL.
        foreach (['localhost:1@evil.example', 'evil.example/.localhost'] as $host) {
            $this->routes($this->client())->handle(Request::fromGlobals(['REQUEST_METHOD' => 'GET', 'REQUEST_URI' => '/cronwatch/', 'HTTP_HOST' => $host], ''));
        }
        $intro = '[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: ';
        $hostless = " on this server (the first request's host is not local, so the link leaves it out)";
        $expected = [
            ['https://app.example.com/cronwatch', ''],
            ['https://app.example.com/cronwatch', ''],
            ['http://localhost:3000/cronwatch', ''],
            ['http://app.localhost:3000/cronwatch', ''],
            ['http://127.0.0.1:3000/cronwatch', ''],
            ['http://127.8.9.10/cronwatch', ''],
            ['http://[::1]:3000/cronwatch', ''],
            ['http://localhost:5173/cronwatch', ''],
            ['/cronwatch', $hostless],
            ['/cronwatch', $hostless],
            ['/cronwatch', $hostless],
            ['/cronwatch', $hostless],
            ['/cronwatch', $hostless],
            ['', $hostless],
            ['/cronwatch', $hostless],
            ['/cronwatch', $hostless],
            ['/cronwatch', $hostless],
            ['/cronwatch', $hostless],
        ];
        $this->assertCount(count($expected), $this->logged);
        foreach ($expected as $i => [$link, $tail]) {
            $this->assertSame(1, preg_match('#token=([A-Za-z0-9_-]{43})#', $this->logged[$i], $token), $this->logged[$i]);
            $this->assertSame("{$intro}{$link}/?token={$token[1]}{$tail}", $this->logged[$i], "line {$i}");
        }
    }

    public function testOnlyAnOriginThatReadsAsOneIsLoopback(): void
    {
        foreach (['http://localhost', 'http://localhost:3000', 'http://app.localhost', 'https://127.0.0.1', 'http://127.8.9.10:1', 'http://[::1]:3000'] as $yes) {
            $this->assertTrue(Dashboard::isLoopbackOrigin($yes), $yes);
        }
        foreach ([
            'http://localhost.example', 'http://128.0.0.1', 'http://127.0.0.256', 'http://10.0.0.5:8080', 'http://[::2]',
            // A Host header that is not a host (the Rust audit).
            'http://evil.example/.localhost', 'http://localhost:1@evil.example', 'http://evil.example?.localhost',
            'http://evil.example#.localhost', 'http://localhost:1@evil.example:80',
        ] as $no) {
            $this->assertFalse(Dashboard::isLoopbackOrigin($no), $no);
        }
    }

    // ------------------------------------------------------------ routes-pwa.test.ts

    public function testTheManifestDescribesTheAppAtItsBasePathWithoutTheToken(): void
    {
        [, $web] = $this->app();
        $res = self::send($web, 'GET', '/cronwatch/manifest.webmanifest');
        $this->assertSame(200, $res->status);
        $this->assertSame('application/manifest+json', $res->header('content-type'));
        $manifest = self::json($res);
        $this->assertSame(['CronWatch', 'CronWatch', '/cronwatch/', '/cronwatch/', '/cronwatch/'], [$manifest['name'], $manifest['short_name'], $manifest['id'], $manifest['start_url'], $manifest['scope']]);
        $this->assertSame(['standalone', '#f4f4f5', '#ffffff'], [$manifest['display'], $manifest['background_color'], $manifest['theme_color']]);
        $this->assertSame([
            ['/cronwatch/icons/icon.svg', 'any', 'image/svg+xml', 'any'],
            ['/cronwatch/icons/maskable.svg', 'any', 'image/svg+xml', 'maskable'],
            ['/cronwatch/icons/icon-192.png', '192x192', 'image/png', 'any'],
            ['/cronwatch/icons/icon-512.png', '512x512', 'image/png', 'any'],
            ['/cronwatch/icons/maskable-512.png', '512x512', 'image/png', 'maskable'],
        ], array_map(fn (array $i) => array_values($i), $manifest['icons']));
    }

    /** @return array<string, array{string, string, string}> */
    public static function basePaths(): array
    {
        return ['empty' => ['', '', ''], 'slash' => ['/', '', ''], 'nested' => ['/ops/cron/', '/ops/cron', '/ops/cron']];
    }

    #[DataProvider('basePaths')]
    public function testTheManifestFollowsTheBasePathWhereverTheRoutesAreMounted(string $basePath, string $prefix, string $base): void
    {
        [, $web] = $this->app('tok', $basePath);
        $manifest = self::json(self::send($web, 'GET', "{$prefix}/manifest.webmanifest"));
        $this->assertSame(["{$base}/", "{$base}/", "{$base}/"], [$manifest['start_url'], $manifest['scope'], $manifest['id']]);
        $this->assertSame("{$base}/icons/icon.svg", $manifest['icons'][0]['src']);
        $this->assertSame("{$base}/", self::send($web, 'GET', "{$prefix}/sw.js")->header('service-worker-allowed'));
    }

    public function testIconsAreServedWithTheirTypesALongCacheAndNoToken(): void
    {
        [, $web] = $this->app();
        foreach (['icon-192.png' => 192, 'icon-512.png' => 512, 'maskable-512.png' => 512, 'apple-touch-icon.png' => 180] as $name => $size) {
            $res = self::send($web, 'GET', "/cronwatch/icons/{$name}");
            $this->assertSame(200, $res->status, $name);
            $this->assertSame('image/png', $res->header('content-type'));
            $this->assertSame('public, max-age=31536000, immutable', $res->header('cache-control'));
            $this->assertNull($res->header('set-cookie'));
            $this->assertSame("\x89PNG\r\n\x1a\n", substr($res->body, 0, 8));
            $this->assertSame([$size, $size], array_values((array) unpack('N2', substr($res->body, 16, 8))), $name);
            $this->assertLessThan(10_000, strlen($res->body));
        }
        foreach (['icon.svg', 'maskable.svg'] as $name) {
            $res = self::send($web, 'GET', "/cronwatch/icons/{$name}");
            $this->assertSame('image/svg+xml', $res->header('content-type'));
            $this->assertSame("default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'", $res->header('content-security-policy'));
            $this->assertMatchesRegularExpression('/<circle cx="20" cy="20" r="10.5"[^>]*stroke-width="2"/', $res->body);
        }
        $this->assertSame(401, self::send($web, 'GET', '/cronwatch/icons/nope.png')->status, 'anything else under /icons needs the token');
    }

    public function testTheAppShellIsPublicEvenWhenTheRoutesAreLockedOrOpened(): void
    {
        putenv('CRONWATCH_ENV=production');
        $cw = $this->client();
        $locked = $this->routes($cw);
        $cw->run('secret-job', self::nothing());
        $this->assertSame(503, self::send($locked, 'GET', '/cronwatch/')->status);
        foreach (['/cronwatch/manifest.webmanifest', '/cronwatch/sw.js', '/cronwatch/app.js', '/cronwatch/offline', '/cronwatch/icons/icon.svg'] as $path) {
            $res = self::send($locked, 'GET', $path);
            $this->assertSame(200, $res->status, $path);
            $this->assertStringNotContainsString('secret-job', $res->body);
        }
        $this->assertSame(200, self::send($this->app(false)[1], 'GET', '/cronwatch/manifest.webmanifest')->status);
    }

    public function testOnlyGetAndHeadReachTheAppShell(): void
    {
        [, $web] = $this->app();
        $this->assertSame(200, self::send($web, 'HEAD', '/cronwatch/sw.js')->status);
        $this->assertSame(401, self::send($web, 'POST', '/cronwatch/sw.js')->status);
        $this->assertSame(404, self::send($web, 'POST', '/cronwatch/manifest.webmanifest', self::BEARER)->status);
    }

    public function testPagesLinkTheManifestIconsAndAppJsUnderTheBase(): void
    {
        [$cw, $web] = $this->app('tok', '/ops/cron');
        $cw->run('h', self::nothing());
        foreach (['/ops/cron/', '/ops/cron/jobs/h', '/ops/cron/nope', '/ops/cron/offline'] as $path) {
            $html = self::send($web, 'GET', $path, self::BEARER)->body;
            $this->assertStringContainsString('<link rel="manifest" href="/ops/cron/manifest.webmanifest">', $html, $path);
            $this->assertStringContainsString('<link rel="icon" href="/ops/cron/icons/icon.svg" type="image/svg+xml">', $html);
            $this->assertStringContainsString('<link rel="apple-touch-icon" href="/ops/cron/icons/apple-touch-icon.png">', $html);
            $this->assertStringContainsString('<meta name="theme-color" content="#111113" media="(prefers-color-scheme: dark)">', $html);
            $this->assertStringContainsString("@media(display-mode:standalone){\n.top{position:sticky;top:0", $html);
        }
    }

    public function testThePageCspAllowsExactlyTheAppShellAndDataStaysUncacheable(): void
    {
        [$cw, $web] = $this->app();
        $cw->run('h', self::nothing());
        foreach (['/cronwatch/', '/cronwatch/jobs/h', '/cronwatch/nope', '/cronwatch/offline'] as $path) {
            $this->assertSame(self::CSP, self::send($web, 'GET', $path, self::BEARER)->header('content-security-policy'), $path);
        }
        foreach (['/cronwatch/', '/cronwatch/jobs/h', '/cronwatch/api/jobs', '/cronwatch/api/jobs/h'] as $path) {
            $this->assertSame('no-store', self::send($web, 'GET', $path, self::BEARER)->header('cache-control'), $path);
        }
        $this->assertSame('no-store', self::send($web, 'GET', '/cronwatch/')->header('cache-control'), 'the sign-in page too');
    }

    public function testTheSignInPageTakesTheTokenInAForm(): void
    {
        [, $web] = $this->app('tok', '/ops/cron');
        $page = self::send($web, 'GET', '/ops/cron/jobs/x');
        $this->assertSame(401, $page->status);
        $this->assertMatchesRegularExpression('#<form class="signin" method="get" action="/ops/cron/"><label for="token">Token</label><input id="token" name="token" type="password" autocomplete="current-password"[^>]*required><button class="primary" type="submit">Sign in</button></form>#', $page->body);
        $res = self::send($web, 'GET', '/ops/cron/?token=tok');
        $this->assertSame([303, '/ops/cron/'], [$res->status, $res->header('location')]);
        $this->assertStringContainsString('; Path=/ops/cron; HttpOnly; SameSite=Lax', (string) $res->header('set-cookie'));
        $this->assertStringNotContainsString('class="signin"', self::send($web, 'GET', '/ops/cron/offline')->body);
    }

    // ------------------------------------------------------------ routes-timeline.test.ts

    /** A board with a daily cron that failed today, an interval job that stopped, and a busy one. */
    private function seeded(): Dashboard
    {
        $this->clock = new Clock(self::T0 - 30 * self::HOUR);
        $cw = $this->client();
        $web = $this->routes($cw, 'tok');
        $day = Js::dateUtc(2026, 0, 5);
        $hourly = $cw->job('hourly', ['schedule' => '0 * * * *', 'timezone' => 'UTC']);
        for ($t = $day - 24 * self::HOUR; $t <= self::T0 - 30 * self::MIN; $t += self::HOUR) {
            $this->clock->set($t);
            $hourly->run(fn () => $this->clock->advance(5 * self::MIN) && false);
        }
        $nightly = $cw->job('nightly', ['schedule' => '0 3 * * *', 'timezone' => 'UTC']);
        $this->clock->set($day + 3 * self::HOUR);
        $this->failing(fn () => $nightly->run(function (): never {
            $this->clock->advance(400);
            throw new \RuntimeException('boom');
        }));
        $sync = $cw->job('sync', ['schedule' => 'every 30m', 'grace' => '5m']);
        $this->clock->set(self::T0 - 2 * self::HOUR);
        $sync->run(fn () => $this->clock->advance(8000) && false);
        $busy = $cw->job('busy', ['schedule' => 'every 5m', 'grace' => '4m']);
        for ($t = self::T0 - 3 * self::HOUR; $t < self::T0; $t += 5 * self::MIN) {
            $this->clock->set($t);
            $busy->run(fn () => $this->clock->advance(1000) && false);
        }
        $this->clock->set(self::T0);
        $cw->check();
        return $web;
    }

    public function testTheBoardDrawsADayTimeline(): void
    {
        $html = self::send($this->seeded(), 'GET', '/cronwatch/', self::BEARER)->body;
        preg_match('#<ol class="lanes">([\s\S]*?)</ol>#', $html, $m);
        $lane = function (string $name) use ($m): string {
            foreach (explode('<li ', $m[1]) as $part) {
                if (str_contains($part, ">{$name}</a>")) {
                    return $part;
                }
            }
            return '';
        };
        $hourly = $lane('hourly');
        $this->assertSame(24, preg_match_all('/<line class="tick"/', $hourly), 'a tick each hour of the last day');
        $this->assertSame(3, preg_match_all('/<line class="tick ahead"/', $hourly), 'and dashed ones ahead');
        $this->assertGreaterThanOrEqual(23, preg_match_all('/class="run ok"/', $hourly));
        $this->assertStringContainsString('<title>hourly: ok at 09:00 UTC, took 5m</title>', $hourly);
        $nightly = $lane('nightly');
        $this->assertMatchesRegularExpression('#class="run bad"[^>]*><title>nightly: failed at 03:00 UTC, took 400ms</title>#', $nightly);
        $this->assertMatchesRegularExpression('#<span class="note[^"]*"[^>]*>failed at 03:00</span>#', $nightly);
        $sync = $lane('sync');
        $this->assertMatchesRegularExpression('#<rect class="missed"[^>]*><title>sync: due 08:00 UTC, nothing started#', $sync);
        $this->assertStringContainsString('>due 08:00, nothing ran</span>', $sync);
        $this->assertSame(36, preg_match_all('/class="run ok"/', $lane('busy')));
        $this->assertMatchesRegularExpression('#<i class="now" style="left:[\d.]+%"></i>#', $html);
        $this->assertMatchesRegularExpression('#<span class="nowlabel"[^>]*>now 09:30</span>#', $html);
        $this->assertStringContainsString('<ul class="vh"><li>busy (every 5m): ', $html);
        $this->assertMatchesRegularExpression('#@media\(prefers-reduced-motion:reduce\)\{[^}]*animation:none!important#', $html);
        $this->assertStringContainsString('<p class="headline">4 jobs, <b>2 needing attention</b>.</p>', $html);
    }

    public function testAJobPageDrawsItsLastSevenDaysTodayFirst(): void
    {
        $html = self::send($this->seeded(), 'GET', '/cronwatch/jobs/hourly', self::BEARER)->body;
        preg_match('#<figure class="timeline week">([\s\S]*?)</figure>#', $html, $m);
        $this->assertSame(7, preg_match_all('/<li class="lane/', $m[1]));
        $this->assertStringContainsString('Today, 5 Jan', $m[1]);
        $this->assertStringContainsString('Sun 4 Jan</span><span class="sched">24 runs', $m[1]);
        $this->assertSame(1, preg_match_all('/class="nowline"/', $m[1]));
    }

    public function testJobNamesAreEscapedInsideTheTimelinesSvgAndNotes(): void
    {
        // Names made through job() are plain, but a store can hold anything another writer put there.
        $store = new MemoryStore();
        $name = "<svg onload=alert(1)>\"&'";
        $store->upsertJob(new JobDefinition(['name' => $name, 'schedule' => '0 * * * *', 'timezone' => 'UTC']), self::T0 - self::HOUR);
        $store->insertRun(new Run('r1', $name, 'failed', self::T0 - 10 * self::MIN, self::T0 - 9 * self::MIN, self::MIN, 'x'));
        $web = $this->routes($this->client(['store' => $store]), false);
        foreach (['/cronwatch/', '/cronwatch/jobs/' . rawurlencode($name)] as $path) {
            $html = self::send($web, 'GET', $path)->body;
            $this->assertStringNotContainsString('<svg onload', $html, $path);
            $this->assertMatchesRegularExpression('#<title>&lt;svg onload=alert\(1\)&gt;&quot;&amp;&\#39;[^<]*: failed at 09:20 UTC#', $html, $path);
        }
    }

    public function testTheBoardDrawsAtMostThirtyLanesAndSaysSo(): void
    {
        $cw = $this->client();
        for ($i = 0; $i < 33; $i++) {
            $cw->run(sprintf('job-%02d', $i), self::nothing());
        }
        $html = self::send($this->routes($cw, false), 'GET', '/cronwatch/')->body;
        $this->assertSame(30, preg_match_all('/<li class="lane">/', $html));
        $this->assertStringContainsString('Showing the first 30 of 33 jobs here', $html);
        $this->assertSame(33, preg_match_all('/<td class="job">/', $html));
    }

    public function testAnEmptyStoreShowsNoTimelineAndHowToDeclareAJob(): void
    {
        $html = self::send($this->routes($this->client(), false), 'GET', '/cronwatch/')->body;
        $this->assertStringContainsString('No jobs yet.', $html);
        $this->assertStringNotContainsString('class="timeline', $html);
        $this->assertStringContainsString('<code>$cw-&gt;job(&#39;name&#39;, [&#39;schedule&#39; =&gt; &#39;0 2 * * *&#39;])</code>', $html);
    }

    public function testAHostCanSayWhatAnEmptyBoardShowsInsteadOfHowToDeclareAJob(): void
    {
        $dashboard = new Dashboard($this->client(), false, '/cronwatch', empty: 'Events appear after the <b>first check</b>.');
        $html = self::send($dashboard, 'GET', '/cronwatch/')->body;
        $this->assertStringContainsString('No jobs yet.', $html);
        $this->assertStringContainsString('<p class="empty">Events appear after the <b>first check</b>.</p>', $html);
        $this->assertStringNotContainsString('$cw-&gt;job(', $html);
    }

    public function testAJobDueMoreOftenThanCanBeDrawnShowsItsCadenceAsALine(): void
    {
        $cw = $this->client();
        $cw->job('minutely', ['schedule' => '* * * * *'])->run(self::nothing());
        $html = self::send($this->routes($cw, false), 'GET', '/cronwatch/')->body;
        $this->assertMatchesRegularExpression('#<line class="cadence"[^>]*><title>minutely: due \* \* \* \* \*, too often to mark each time</title>#', $html);
        $this->assertDoesNotMatchRegularExpression('#class="tick[^"]*" x1="[\d.]+" y1="6"#', $html);
    }

    // ------------------------------------------------------------ PHP's servers

    public function testTheSuperglobalsAreReadAsAServerFillsThem(): void
    {
        [$cw, $web] = $this->app(false, null);
        $cw->run('x', self::nothing());
        // A path-info URL is mounted at its script.
        $server = ['REQUEST_METHOD' => 'GET', 'REQUEST_URI' => '/tools/cronwatch.php/jobs/x', 'SCRIPT_NAME' => '/tools/cronwatch.php',
            'SCRIPT_FILENAME' => '/var/www/tools/cronwatch.php', 'PATH_INFO' => '/jobs/x', 'HTTP_HOST' => 'App.Test:8080', 'HTTPS' => 'on'];
        $request = Request::fromGlobals($server, '');
        $this->assertSame('https://app.test:8080', $request->origin);
        $this->assertSame('/tools/cronwatch.php', $request->mount);
        $page = $web->handle($request);
        $this->assertSame(200, $page->status);
        $this->assertStringContainsString('<link rel="manifest" href="/tools/cronwatch.php/manifest.webmanifest">', $page->body);
        // Behind a rewrite to a front controller the script is not in the path, and the base is the default.
        $rewritten = Request::fromGlobals(['REQUEST_METHOD' => 'GET', 'REQUEST_URI' => '/cronwatch/jobs/x?a=1', 'SCRIPT_NAME' => '/index.php',
            'SCRIPT_FILENAME' => '/var/www/index.php', 'SERVER_NAME' => 'app.test', 'SERVER_PORT' => '8080', 'QUERY_STRING' => 'a=1'], '');
        $this->assertNull($rewritten->mount);
        $this->assertSame(['http://app.test:8080', '/cronwatch/jobs/x', 'a=1'], [$rewritten->origin, $rewritten->path, $rewritten->query]);
        $this->assertSame(200, $web->handle($rewritten)->status);
        // php -S with a router names the request path the script; that is not a mount.
        $router = Request::fromGlobals(['REQUEST_METHOD' => 'GET', 'REQUEST_URI' => '/cronwatch/api/jobs', 'SCRIPT_NAME' => '/cronwatch/api/jobs',
            'SCRIPT_FILENAME' => '/srv/router.php', 'HTTP_HOST' => 'localhost:8000'], '');
        $this->assertNull($router->mount);
        // Apache without CGIPassAuth hands the header over as REDIRECT_HTTP_AUTHORIZATION.
        $this->assertSame('Bearer tok', Request::fromGlobals(['REQUEST_METHOD' => 'GET', 'REQUEST_URI' => '/', 'REDIRECT_HTTP_AUTHORIZATION' => 'Bearer tok'], '')->header('authorization'));
    }

    public function testPathsAreReadAsTheUrlParserLeavesThem(): void
    {
        $this->assertSame('/cronwatch/api/jobs', Request::normalizePath('/cronwatch/jobs/../api/./jobs'));
        $this->assertSame('/cronwatch/api/', Request::normalizePath('/cronwatch/api/jobs/%2E%2e'));
        $this->assertSame('/a%20b/%22q%22/%C3%A9', Request::normalizePath("/a b/\"q\"/\u{e9}"));
        $this->assertSame('/a/b', Request::normalizePath('\\a\\b'));
        $this->assertSame('/', Request::normalizePath(''));
    }

    public function testThePsrMiddlewareAnswersUnderItsBaseAndPassesTheRestOn(): void
    {
        [$cw, $web] = $this->app('tok', '/ops/cron');
        $cw->run('x', self::nothing());
        $factory = new Psr17Factory();
        $middleware = new PsrMiddleware($web, $factory, $factory, '/ops/cron');
        $next = new class ($factory) implements RequestHandlerInterface {
            public function __construct(private readonly Psr17Factory $factory)
            {
            }

            public function handle(ServerRequestInterface $request): ResponseInterface
            {
                return $this->factory->createResponse(418);
            }
        };
        $mine = $middleware->process($factory->createServerRequest('GET', 'https://app.test/ops/cron/api/jobs/x')->withHeader('Authorization', 'Bearer tok'), $next);
        $this->assertSame(200, $mine->getStatusCode());
        $this->assertSame('application/json; charset=utf-8', $mine->getHeaderLine('content-type'));
        $this->assertSame('x', json_decode((string) $mine->getBody(), true)['job']['name']);
        $this->assertSame(418, $middleware->process($factory->createServerRequest('GET', 'https://app.test/ops/other'), $next)->getStatusCode());
        $this->assertSame(418, $middleware->process($factory->createServerRequest('GET', 'https://app.test/ops/cronjobs'), $next)->getStatusCode());
    }

    public function testToFixedIsJavaScriptsRounding(): void
    {
        foreach ([[1.005, 2, '1.00'], [0.25, 1, '0.3'], [0.35, 1, '0.3'], [2.5, 0, '3'], [-0.04, 1, '-0.0'], [0.0, 1, '0.0'], [123.456, 4, '123.4560'],
            [999.95, 1, '1000.0'], [1e21, 1, '1e+21'], [0.123456, 4, '0.1235'], [7, 1, '7.0']] as [$value, $digits, $expected]) {
            $this->assertSame($expected, Text::toFixed($value, $digits), "{$value}.toFixed({$digits})");
        }
        $this->assertSame("a-b_c.d!e~f*g'h(i)j%20%C3%A9%2F", Text::encodeUriComponent("a-b_c.d!e~f*g'h(i)j \u{e9}/"));
    }
}
