<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Alert;
use Cronwatch\Bridge\EmbeddedDashboard;
use Cronwatch\Bridge\TestAlert;
use Cronwatch\Cronwatch;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Web\Dashboard;
use Cronwatch\Web\Request;
use Cronwatch\Web\Response;
use PHPUnit\Framework\TestCase;

/**
 * The dashboard inside a CMS's admin (Bridge\EmbeddedDashboard, which the
 * Drupal module and the Craft plugin use), and the settings pages' test
 * alert (Bridge\TestAlert). The modules' own tests drive both in a real
 * Drupal and a real Craft.
 */
final class EmbeddedDashboardTest extends TestCase
{
    /** The host's URL for a dashboard path, as a CMS's URL generator would make it. */
    private static function url(): \Closure
    {
        return fn (string $path, array $query): string => '/admin/cw?' . http_build_query(['cw' => $path] + $query, '', '&', PHP_QUERY_RFC3986);
    }

    private static function dashboard(): Dashboard
    {
        $cw = new Cronwatch(store: new MemoryStore(), alerts: [], cronSecret: null);
        $cw->job('nightly:report', ['schedule' => '0 2 * * *', 'timezone' => 'UTC']);
        $cw->run('nightly:report', fn () => 'done');
        return new Dashboard($cw, token: null, basePath: EmbeddedDashboard::MARKER, origin: 'https://site.example');
    }

    public function testTheRequestIsTheDashboardsPathWithTheHostsKeysLeftOut(): void
    {
        $host = Request::create('POST', 'https://site.example/admin/cw?cw=%2Fjobs%2Fx%2Fsilence&token=abc&runs=50', ['origin' => 'https://site.example'], 'for=1h');
        $inner = EmbeddedDashboard::request($host, '/jobs/x/silence', ['cw', 'token']);
        $this->assertSame('POST', $inner->method);
        $this->assertSame(EmbeddedDashboard::MARKER . '/jobs/x/silence', $inner->path);
        $this->assertSame('runs=50', $inner->query);
        $this->assertSame('for=1h', $inner->body());
        $this->assertSame('https://site.example', $inner->origin);
        $this->assertSame('https://site.example', $inner->header('origin'));
        $this->assertSame(EmbeddedDashboard::MARKER . '/', EmbeddedDashboard::request($host, '', ['cw'])->path);
    }

    public function testLinksFormsAndRedirectsPointIntoTheHost(): void
    {
        $dashboard = self::dashboard();
        $page = $dashboard->handle(Request::create('GET', 'https://site.example' . EmbeddedDashboard::MARKER . '/'));
        $this->assertSame(200, $page->status);
        $this->assertStringContainsString(EmbeddedDashboard::MARKER, $page->body);

        $rewritten = EmbeddedDashboard::rewrite($page, self::url(), fn (string $url): string => $url . '&token=t1', '<input type="hidden" name="csrf" value="v$1">');
        $this->assertStringNotContainsString(EmbeddedDashboard::MARKER, $rewritten->body, 'every link points into the host');
        $this->assertStringNotContainsString('manifest.webmanifest', $rewritten->body);
        $this->assertStringNotContainsString('app.js', $rewritten->body);
        $this->assertStringContainsString('href="/admin/cw?cw=%2Fjobs%2Fnightly%253Areport"', $rewritten->body, 'a job link, its path escaped once more');
        $this->assertStringContainsString('<form class="inline" method="post" action="/admin/cw?cw=%2Fcheck&amp;token=t1"><input type="hidden" name="csrf" value="v$1">', $rewritten->body, 'the token on the action, the field in the form');
        $this->assertStringContainsString("frame-ancestors 'self'", $rewritten->headers['content-security-policy']);
        $this->assertSame('SAMEORIGIN', $rewritten->headers['x-frame-options'] ?? 'SAMEORIGIN');

        $redirect = $dashboard->handle(Request::create('POST', 'https://site.example' . EmbeddedDashboard::MARKER . '/jobs/nightly%3Areport/silence', ['origin' => 'https://site.example', 'content-type' => 'application/x-www-form-urlencoded'], 'for=1h'));
        $this->assertSame(303, $redirect->status);
        $this->assertSame('/admin/cw?cw=%2F', EmbeddedDashboard::rewrite($redirect, self::url())->headers['location'], 'back to the board without a referer');
        // With one (the host's page the form was on), back to it as it is.
        $back = 'https://site.example/admin/cw?cw=%2Fjobs%2Fnightly%253Areport';
        $redirect = $dashboard->handle(Request::create('POST', 'https://site.example' . EmbeddedDashboard::MARKER . '/jobs/nightly%3Areport/unsilence', ['origin' => 'https://site.example', 'referer' => $back]));
        $this->assertSame($back, EmbeddedDashboard::rewrite($redirect, self::url())->headers['location']);
    }

    public function testAPathsOwnQueryBecomesTheHostsParameters(): void
    {
        $response = new Response(200, ['content-type' => 'text/html; charset=utf-8'], '<a href="' . EmbeddedDashboard::MARKER . '/jobs/a?runs=100&amp;x=1">more</a>');
        $this->assertSame('<a href="/admin/cw?cw=%2Fjobs%2Fa&amp;runs=100&amp;x=1">more</a>', EmbeddedDashboard::rewrite($response, self::url())->body);
    }

    public function testJsonIsLeftAsItIs(): void
    {
        $response = new Response(200, ['content-type' => 'application/json; charset=utf-8'], '{"path":"' . EmbeddedDashboard::MARKER . '/x"}');
        $this->assertSame($response->body, EmbeddedDashboard::rewrite($response, self::url())->body);
    }

    public function testTheTestAlertSaysWhatEachChannelAnswered(): void
    {
        $seen = [];
        $results = TestAlert::send([
            function (Alert $alert) use (&$seen): void {
                $seen[] = [$alert->job, $alert->title, $alert->message];
            },
            function (Alert $alert): void {
                throw new \RuntimeException('refused');
            },
        ], 'https://site.example');
        $this->assertSame([['cronwatch-test', 'CronWatch test alert', 'A test alert from https://site.example. If you can read this, CronWatch alerts reach you.']], $seen);
        $this->assertSame([
            ['channel' => 'custom', 'ok' => true, 'message' => ''],
            ['channel' => 'custom', 'ok' => false, 'message' => 'refused'],
        ], $results);
    }
}
