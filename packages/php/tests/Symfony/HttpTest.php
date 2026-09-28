<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Symfony;

use Cronwatch\Cronwatch;
use Cronwatch\Job\JobContext;

/**
 * The dashboard's routes imported under /cronwatch, behind the app's
 * security (a user with ROLE_ADMIN is let in by the app's sign-in; anyone
 * else needs the dashboard's token), and a job's handler() in a controller.
 */
final class HttpTest extends TestCase
{
    private const TOKEN = 'dash-token-for-tests';

    private function seeded(): Cronwatch
    {
        $cw = $this->client(['cronSecret' => 'cron-secret-for-tests']);
        $cw->job('nightly', ['schedule' => '0 2 * * *', 'timezone' => 'UTC'])->run(fn (JobContext $job) => $job->log('ok'));
        return $cw;
    }

    public function testAnAdminIsLetInByTheAppsSignIn(): void
    {
        $browser = static::createClient(['cronwatch' => ['store' => 'memory', 'dashboard' => ['token' => self::TOKEN]]]);
        $browser->disableReboot();
        $this->seeded();
        $browser->request('GET', '/cronwatch', server: ['PHP_AUTH_USER' => 'admin', 'PHP_AUTH_PW' => 'pw']);
        $response = $browser->getResponse();
        $this->assertSame(200, $response->getStatusCode());
        $this->assertStringContainsString('nightly', (string) $response->getContent());
        $this->assertStringContainsString("default-src 'none'", (string) $response->headers->get('content-security-policy'));
        $this->assertStringContainsString('href="/cronwatch/jobs/nightly"', (string) $response->getContent());
        $browser->request('GET', '/cronwatch/jobs/nightly', server: ['PHP_AUTH_USER' => 'admin', 'PHP_AUTH_PW' => 'pw']);
        $this->assertSame(200, $browser->getResponse()->getStatusCode());
    }

    public function testAJobNameWithAnEscapeInItsPathIsItsOwnPage(): void
    {
        // The router decodes {path} (billing:sync); the path info keeps billing%3Async.
        $browser = static::createClient(['cronwatch' => ['store' => 'memory', 'dashboard' => ['token' => self::TOKEN]]]);
        $browser->disableReboot();
        $cw = $this->seeded();
        $cw->job('billing:sync')->run(fn () => 'synced');
        $admin = ['PHP_AUTH_USER' => 'admin', 'PHP_AUTH_PW' => 'pw'];
        $browser->request('GET', '/cronwatch/jobs/billing%3Async', server: $admin);
        $this->assertSame(200, $browser->getResponse()->getStatusCode());
        $this->assertStringContainsString('synced', (string) $browser->getResponse()->getContent());
        $browser->request('GET', '/cronwatch/api/jobs/billing%3Async', server: ['HTTP_AUTHORIZATION' => 'Bearer ' . self::TOKEN]);
        $this->assertSame('billing:sync', json_decode((string) $browser->getResponse()->getContent(), true)['job']['name']);
        $browser->request('POST', '/cronwatch/jobs/billing%3Async/forget', [], server: $admin + ['HTTP_ORIGIN' => 'http://localhost']);
        $this->assertSame(303, $browser->getResponse()->getStatusCode());
        $this->assertNull($cw->store->getJob('billing:sync'));
    }

    public function testAnyoneElseNeedsTheDashboardsToken(): void
    {
        $browser = static::createClient(['cronwatch' => ['store' => 'memory', 'dashboard' => ['token' => self::TOKEN]]]);
        $browser->disableReboot();
        $this->seeded();
        $browser->request('GET', '/cronwatch/api/jobs', server: ['PHP_AUTH_USER' => 'viewer', 'PHP_AUTH_PW' => 'pw']);
        $this->assertSame(401, $browser->getResponse()->getStatusCode());
        $browser->request('GET', '/cronwatch/api/jobs');
        $this->assertSame(401, $browser->getResponse()->getStatusCode());
        $browser->request('GET', '/cronwatch/api/jobs', server: ['HTTP_AUTHORIZATION' => 'Bearer ' . self::TOKEN]);
        $this->assertSame(200, $browser->getResponse()->getStatusCode());
        $this->assertSame('nightly', json_decode((string) $browser->getResponse()->getContent(), true)['jobs'][0]['name']);
        $browser->request('POST', '/cronwatch/api/check', server: ['HTTP_AUTHORIZATION' => 'Bearer cron-secret-for-tests']);
        $this->assertSame(200, $browser->getResponse()->getStatusCode(), 'CRON_SECRET runs the check');
    }

    public function testChangesAreRefusedFromAnotherSite(): void
    {
        $browser = static::createClient(['cronwatch' => ['store' => 'memory', 'dashboard' => ['token' => self::TOKEN]]]);
        $browser->disableReboot();
        $cw = $this->seeded();
        $admin = ['PHP_AUTH_USER' => 'admin', 'PHP_AUTH_PW' => 'pw'];
        $browser->request('POST', '/cronwatch/jobs/nightly/silence', ['duration' => '1h'], server: $admin + ['HTTP_ORIGIN' => 'http://localhost']);
        $this->assertSame(303, $browser->getResponse()->getStatusCode());
        $this->assertNotNull($cw->store->getState('nightly')->silencedUntil);
        $browser->request('POST', '/cronwatch/jobs/nightly/unsilence', [], server: $admin + ['HTTP_ORIGIN' => 'https://evil.example']);
        $this->assertSame(403, $browser->getResponse()->getStatusCode());
    }

    public function testAJobHandlerInAController(): void
    {
        $browser = static::createClient();
        $browser->disableReboot();
        $cw = $this->client(['cronSecret' => 'cron-secret-for-tests']);
        $browser->request('POST', '/cron/nightly');
        $this->assertSame(401, $browser->getResponse()->getStatusCode());
        $browser->request('POST', '/cron/nightly', server: ['HTTP_AUTHORIZATION' => 'Bearer cron-secret-for-tests']);
        $response = $browser->getResponse();
        $this->assertSame(200, $response->getStatusCode());
        $run = $cw->runs('nightly')[0];
        $this->assertSame('{"ok":true,"job":"nightly","run":"' . $run->id . '","status":"ok","durationMs":0}', $response->getContent());
        $this->assertSame(['handler', '/cron/nightly'], [$run->trigger, $run->output]);
        $this->assertSame('application/json; charset=utf-8', $response->headers->get('content-type'));
        $browser->request('GET', '/cron/down', server: ['HTTP_AUTHORIZATION' => 'Bearer cron-secret-for-tests']);
        $this->assertSame(503, $browser->getResponse()->getStatusCode());
        $this->assertSame('{"down":true}', $browser->getResponse()->getContent());
        $this->assertSame('HTTP 503 Service Unavailable', $cw->runs('down')[0]->error);
    }
}
