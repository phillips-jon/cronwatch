<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Laravel;

use Cronwatch\Cronwatch;
use Cronwatch\Job\JobContext;
use Cronwatch\Laravel\Http\Authorize;
use Illuminate\Foundation\Auth\User;
use Illuminate\Http\Request;
use Illuminate\Http\Response;
use Illuminate\Support\Facades\Gate;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Route;
use Orchestra\Testbench\Attributes\DefineEnvironment;

/**
 * The dashboard mounted in the app (behind the viewCronwatch gate, without
 * Laravel's CSRF middleware, a bearer token for the API), and a job's
 * handler() as a Laravel route.
 */
final class HttpTest extends TestCase
{
    private const TOKEN = 'dash-token-for-tests';

    protected function defineEnvironment($app): void
    {
        parent::defineEnvironment($app);
        $app['config']->set('cronwatch.dashboard.token', self::TOKEN);
        $app['config']->set('app.key', 'base64:' . base64_encode(str_repeat('k', 32)));
    }

    protected function local($app): void
    {
        $app['env'] = 'local';
    }

    private function seeded(): Cronwatch
    {
        $cw = $this->client();
        $cw->job('nightly', ['schedule' => '0 2 * * *', 'timezone' => 'UTC'])->run(fn (JobContext $job) => $job->log('ok'));
        return $cw;
    }

    #[DefineEnvironment('local')]
    public function testTheGateLetsEveryoneInLocallyAndTheDashboardAnswersUnderItsPath(): void
    {
        $this->seeded();
        $page = $this->get('/cronwatch');
        $page->assertOk();
        $this->assertStringStartsWith('text/html', (string) $page->headers->get('content-type'));
        $this->assertStringContainsString('nightly', (string) $page->getContent());
        $this->assertStringContainsString("default-src 'none'", (string) $page->headers->get('content-security-policy'));
        $this->get('/cronwatch/jobs/nightly')->assertOk()->assertSee('nightly');
        $this->get('/cronwatch/api/jobs')->assertOk()->assertJsonPath('jobs.0.name', 'nightly');
    }

    public function testOutsideLocalTheGateRefusesAGuestAndLetsInWhoItIsDefinedFor(): void
    {
        $this->seeded();
        $this->get('/cronwatch')->assertForbidden();
        Gate::define(Authorize::GATE, fn (?User $user = null) => $user?->getAttribute('email') === 'ops@example.com');
        $this->get('/cronwatch')->assertForbidden();
        $this->actingAs((new User())->forceFill(['email' => 'someone@example.com']))->get('/cronwatch')->assertForbidden();
        $this->actingAs((new User())->forceFill(['email' => 'ops@example.com']))->get('/cronwatch')->assertOk();
    }

    public function testABearerSkipsTheGateAndMustBeTheDashboardsToken(): void
    {
        $this->seeded();
        $this->getJson('/cronwatch/api/jobs', ['Authorization' => 'Bearer ' . self::TOKEN])->assertOk()->assertJsonPath('jobs.0.name', 'nightly');
        $this->getJson('/cronwatch/api/jobs', ['Authorization' => 'Bearer wrong'])->assertUnauthorized();
    }

    #[DefineEnvironment('local')]
    public function testChangesNeedNoCsrfTokenButAreRefusedFromAnotherSite(): void
    {
        $cw = $this->seeded();
        $this->post('/cronwatch/jobs/nightly/silence', ['duration' => '1h'], ['Origin' => 'http://localhost'])->assertRedirect();
        $this->assertNotNull($cw->store->getState('nightly')->silencedUntil);
        $this->post('/cronwatch/jobs/nightly/unsilence', [], ['Origin' => 'https://evil.example'])->assertForbidden();
        $this->assertNotNull($cw->store->getState('nightly')->silencedUntil);
    }

    protected function elsewhere($app): void
    {
        $this->local($app);
        $app['config']->set('cronwatch.dashboard.path', 'ops/cron');
    }

    #[DefineEnvironment('elsewhere')]
    public function testThePathIsConfigurable(): void
    {
        $this->seeded();
        $this->get('/cronwatch')->assertNotFound();
        $page = $this->get('/ops/cron');
        $page->assertOk();
        $this->assertStringContainsString('href="/ops/cron/jobs/nightly"', (string) $page->getContent());
    }

    protected function withoutTheGatesMiddleware($app): void
    {
        $app['config']->set('cronwatch.dashboard.middleware', ['web']);
    }

    #[DefineEnvironment('withoutTheGatesMiddleware')]
    public function testTheControllerAsksTheGateItselfWhenTheMiddlewareIsTakenOut(): void
    {
        $this->seeded();
        $this->get('/cronwatch/api/jobs')->assertUnauthorized();
        Gate::define(Authorize::GATE, fn (?User $user = null) => $user?->getAttribute('email') === 'ops@example.com');
        $this->actingAs((new User())->forceFill(['email' => 'someone@example.com']))->get('/cronwatch/api/jobs')->assertUnauthorized();
        $this->actingAs((new User())->forceFill(['email' => 'ops@example.com']))->get('/cronwatch/api/jobs')->assertOk();
        $this->getJson('/cronwatch/api/jobs', ['Authorization' => 'Bearer ' . self::TOKEN])->assertOk();
    }

    protected function noDashboard($app): void
    {
        $this->local($app);
        $app['config']->set('cronwatch.dashboard.enabled', false);
    }

    #[DefineEnvironment('noDashboard')]
    public function testTheDashboardCanBeLeftOff(): void
    {
        $this->get('/cronwatch')->assertNotFound();
    }

    public function testAJobHandlerIsALaravelRoute(): void
    {
        $cw = $this->client(['cronSecret' => 'cron-secret-for-tests']);
        Route::post('/cron/nightly', $cw->job('nightly')->handler(function (JobContext $job, Request $request): void {
            $job->log($request->path());
        })->laravel());
        Route::get('/cron/down', fn (Request $request) => $cw->job('down')->handler(fn () => response()->json(['down' => true], 503))($request));
        Route::get('/cron/array', $cw->job('array')->handler(fn () => ['status' => 202, 'body' => 'queued'])->laravel());

        $this->postJson('/cron/nightly')->assertUnauthorized()->assertExactJson(['ok' => false, 'error' => 'Unauthorized']);
        $ok = $this->postJson('/cron/nightly', [], ['Authorization' => 'Bearer cron-secret-for-tests']);
        $ok->assertOk();
        $this->assertInstanceOf(Response::class, $ok->baseResponse);
        $run = $cw->runs('nightly')[0];
        $this->assertSame('{"ok":true,"job":"nightly","run":"' . $run->id . '","status":"ok","durationMs":0}', $ok->getContent());
        $this->assertSame(['handler', 'cron/nightly'], [$run->trigger, $run->output]);
        $this->assertStringStartsWith('no-store', (string) $ok->headers->get('cache-control'), 'HttpFoundation adds "private"');

        $down = $this->getJson('/cron/down', ['Authorization' => 'Bearer cron-secret-for-tests']);
        $down->assertStatus(503)->assertExactJson(['down' => true]);
        $this->assertSame('HTTP 503 Service Unavailable', $cw->runs('down')[0]->error);

        $array = $this->get('/cron/array', ['Authorization' => 'Bearer cron-secret-for-tests']);
        $array->assertStatus(202);
        $this->assertSame('queued', $array->getContent());
    }

    public function testAnAlertSentInsideARequestLinksToAppUrlNotTheRequestsHost(): void
    {
        $this->app['config']->set('app.url', 'https://ops.example');
        $this->app['config']->set('cronwatch.alerts.slack', 'https://hooks.slack.test/services/T/B/x');
        $http = new \Cronwatch\Tests\Support\FakeHttp();
        \Cronwatch\Alerts\Transport::set($http);
        try {
            Route::get('/breaks', function () {
                try {
                    app(Cronwatch::class)->job('sync-orders')->run(fn () => throw new \RuntimeException('down'));
                } catch (\RuntimeException) {
                }
                return 'done';
            });
            $this->get('http://evil.example/breaks')->assertOk();
            $this->assertCount(1, $http->requests);
            $body = $http->requests[0]['body'];
            $this->assertStringContainsString('https://ops.example/cronwatch/jobs/sync-orders', $body);
            $this->assertStringNotContainsString('evil.example', $body);

            // The dashboard on a domain of its own links there, in app.url's scheme.
            $this->app['config']->set('cronwatch.dashboard.domain', 'cron.ops.example');
            $this->app->forgetInstance(Cronwatch::class);
            $this->get('http://evil.example/breaks')->assertOk();
            $this->assertCount(2, $http->requests);
            $this->assertStringContainsString('https://cron.ops.example/cronwatch/jobs/sync-orders', $http->requests[1]['body']);
        } finally {
            \Cronwatch\Alerts\Transport::set(null);
        }
    }

    public function testAnHttpClientResponseIsARunOutcome(): void
    {
        $cw = $this->client();
        Http::fake(['https://api.example.com/*' => Http::response('down', 503)]);
        $cw->job('pinger')->run(fn () => Http::get('https://api.example.com/ping'));
        $this->assertSame(['failed', 'HTTP 503 Service Unavailable'], [$cw->runs('pinger')[0]->status, $cw->runs('pinger')[0]->error]);
    }

    public function testWithNoTokenConfiguredTheApiStaysLocked(): void
    {
        self::withoutSecrets(function (): void {
            $this->app['config']->set('cronwatch.dashboard.token', null);
            $this->seeded();
            $status = $this->getJson('/cronwatch/api/jobs', ['Authorization' => 'Bearer anything'])->getStatusCode();
            $this->assertContains($status, [401, 503], 'an unset token reads CRONWATCH_TOKEN; it never turns the token off');
        });
    }

    /** Runs $body with CRONWATCH_TOKEN and CRON_SECRET unset everywhere PHP reads them. */
    private static function withoutSecrets(callable $body): void
    {
        $saved = [];
        foreach (['CRONWATCH_TOKEN', 'CRON_SECRET'] as $name) {
            $saved[$name] = [getenv($name), $_SERVER[$name] ?? null, $_ENV[$name] ?? null];
            putenv($name);
            unset($_SERVER[$name], $_ENV[$name]);
        }
        try {
            $body();
        } finally {
            foreach ($saved as $name => [$env, $server, $envArray]) {
                putenv($env === false ? $name : "{$name}={$env}");
                if ($server !== null) {
                    $_SERVER[$name] = $server;
                }
                if ($envArray !== null) {
                    $_ENV[$name] = $envArray;
                }
            }
        }
    }
}
