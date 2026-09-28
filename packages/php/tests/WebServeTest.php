<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use PHPUnit\Framework\TestCase;

/**
 * serve(), the plain entry: a real `php -S` running tests/servers/web.php,
 * which answers from the superglobals with header() and echo, as a bare
 * public/cronwatch.php would. What goes over the wire is the SDK's status,
 * headers and body, and nothing PHP adds by itself (X-Powered-By, a default
 * Content-Type on a redirect); HEAD gets the headers only.
 */
final class WebServeTest extends TestCase
{
    /** @var resource|null */
    private static $server = null;
    private static string $url = '';
    private static string $dir = '';

    public static function setUpBeforeClass(): void
    {
        if (!extension_loaded('pdo_sqlite') || !function_exists('proc_open')) {
            return;
        }
        $probe = stream_socket_server('tcp://127.0.0.1:0');
        $name = (string) stream_socket_get_name($probe, false);
        fclose($probe);
        $port = (int) substr($name, strrpos($name, ':') + 1);
        self::$dir = sys_get_temp_dir() . '/cronwatch-serve-' . getmypid() . '-' . bin2hex(random_bytes(4));
        mkdir(self::$dir);
        self::$url = "http://127.0.0.1:{$port}";
        // expose_php on, as many installs have it, so a leaked X-Powered-By would show.
        self::$server = proc_open(
            [PHP_BINARY, '-d', 'expose_php=1', '-S', "127.0.0.1:{$port}", __DIR__ . '/servers/web.php'],
            [0 => ['file', '/dev/null', 'r'], 1 => ['file', self::$dir . '/out.log', 'w'], 2 => ['file', self::$dir . '/out.log', 'w']],
            $pipes,
            null,
            ['CW_WEB_DB' => self::$dir . '/cronwatch.db', 'PATH' => (string) getenv('PATH')],
        );
        for ($i = 0; $i < 100; $i++) {
            $socket = @stream_socket_client("tcp://127.0.0.1:{$port}", $errno, $error, 0.1);
            if ($socket !== false) {
                fclose($socket);
                return;
            }
            usleep(50_000);
        }
    }

    public static function tearDownAfterClass(): void
    {
        if (is_resource(self::$server)) {
            proc_terminate(self::$server);
            proc_close(self::$server);
        }
        foreach (glob(self::$dir . '/*') ?: [] as $file) {
            @unlink($file);
        }
        @rmdir(self::$dir);
    }

    protected function setUp(): void
    {
        if (!is_resource(self::$server)) {
            $this->markTestSkipped('needs pdo_sqlite and proc_open');
        }
    }

    /**
     * @param array<string, string> $headers
     * @return array{int, array<string, string>, string}
     */
    private static function fetch(string $method, string $path, array $headers = [], string $body = ''): array
    {
        $lines = [];
        foreach ($headers as $name => $value) {
            $lines[] = "{$name}: {$value}";
        }
        $context = stream_context_create(['http' => ['method' => $method, 'header' => $lines, 'content' => $body, 'ignore_errors' => true, 'follow_location' => 0, 'timeout' => 10]]);
        $text = (string) @file_get_contents(self::$url . $path, false, $context);
        // http_get_last_response_headers() is 8.4's; before it the headers land in a local variable.
        $received = function_exists('http_get_last_response_headers') ? http_get_last_response_headers() : ($http_response_header ?? []);
        $status = 0;
        $out = [];
        foreach ($received ?? [] as $line) {
            if (preg_match('#^HTTP/\S+ (\d{3})#', $line, $m) === 1) {
                $status = (int) $m[1];
                continue;
            }
            [$name, $value] = array_map('trim', explode(':', $line, 2) + [1 => '']);
            $out[strtolower($name)] = $value;
        }
        unset($out['host'], $out['date'], $out['connection']);
        ksort($out);
        return [$status, $out, $text];
    }

    public function testTheSdksHeadersGoOverTheWireAndNothingPhpAddsOnItsOwn(): void
    {
        [$status, $headers, $body] = self::fetch('GET', '/cronwatch/api/jobs', ['Authorization' => 'Bearer tok']);
        $this->assertSame(200, $status);
        $this->assertSame([
            'cache-control' => 'no-store',
            'content-length' => (string) strlen($body),
            'content-type' => 'application/json; charset=utf-8',
            'referrer-policy' => 'same-origin',
            'x-content-type-options' => 'nosniff',
            'x-robots-tag' => 'noindex',
        ], $headers);
        $this->assertSame('nightly', json_decode($body, true)['jobs'][0]['name']);

        [$status, $headers, $body] = self::fetch('GET', '/cronwatch/?token=tok&view=all');
        $this->assertSame(303, $status);
        $this->assertSame('/cronwatch/?view=all', $headers['location']);
        $this->assertArrayNotHasKey('content-type', $headers, 'a redirect has no body, so no type');
        $this->assertStringStartsWith('cronwatch_token=' . hash('sha256', 'cronwatch-cookie:tok') . '; Path=/cronwatch; HttpOnly', $headers['set-cookie']);
        $this->assertSame('', $body);

        [$status, $headers, $body] = self::fetch('GET', '/cronwatch/jobs/nightly', ['Cookie' => 'cronwatch_token=' . hash('sha256', 'cronwatch-cookie:tok')]);
        $this->assertSame(200, $status);
        $this->assertSame('DENY', $headers['x-frame-options']);
        $this->assertStringStartsWith("<!doctype html>\n", $body);
        $this->assertStringContainsString('<h1 class="jobname">nightly</h1>', $body);
        $this->assertArrayNotHasKey('x-powered-by', $headers);
    }

    public function testHeadGetsTheHeadersAndNoBodyAndFormsWork(): void
    {
        [$status, $headers, $body] = self::fetch('HEAD', '/cronwatch/sw.js');
        $this->assertSame(200, $status);
        $this->assertSame('/cronwatch/', $headers['service-worker-allowed']);
        $this->assertGreaterThan(0, (int) $headers['content-length']);
        $this->assertSame('', $body);

        [$status, $headers] = self::fetch('POST', '/cronwatch/jobs/nightly/silence', ['Authorization' => 'Bearer tok', 'Content-Type' => 'application/x-www-form-urlencoded',
            'Origin' => self::$url, 'Referer' => self::$url . '/cronwatch/jobs/nightly'], 'for=4h');
        $this->assertSame(303, $status);
        $this->assertSame(self::$url . '/cronwatch/jobs/nightly', $headers['location']);
        [, , $json] = self::fetch('GET', '/cronwatch/api/jobs/nightly', ['Authorization' => 'Bearer tok']);
        $this->assertSame('silenced', json_decode($json, true)['job']['health']);

        $boundary = 'cwboundary';
        [$status] = self::fetch('POST', '/cronwatch/jobs/nightly/silence', ['Authorization' => 'Bearer tok', 'Content-Type' => "multipart/form-data; boundary={$boundary}"],
            "--{$boundary}\r\nContent-Disposition: form-data; name=\"for\"\r\n\r\nforever\r\n--{$boundary}--\r\n");
        $this->assertSame(400, $status, 'a multipart form PHP read itself ($_POST) is read too');
        [$status] = self::fetch('POST', '/cronwatch/api/jobs/nightly/unsilence', ['Authorization' => 'Bearer tok', 'Origin' => 'https://evil.example']);
        $this->assertSame(403, $status);
        [$status, $headers, $body] = self::fetch('GET', '/elsewhere');
        $this->assertSame([404, 'not found'], [$status, $body], 'the front controller passes on what is not under /cronwatch');
    }
}
