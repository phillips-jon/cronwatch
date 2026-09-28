<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Support;

/**
 * A `php -S` server on 127.0.0.1 running tests/servers/router.php, which
 * records every request it is sent. For the tests of the real HTTP paths.
 */
final class LocalServer
{
    /** @var resource */
    private $process;
    private readonly string $log;
    public readonly string $url;

    public function __construct()
    {
        $probe = stream_socket_server('tcp://127.0.0.1:0');
        $name = stream_socket_get_name($probe, false);
        fclose($probe);
        $port = (int) substr((string) $name, strrpos((string) $name, ':') + 1);
        $this->log = sys_get_temp_dir() . '/cronwatch-php-server-' . getmypid() . '-' . bin2hex(random_bytes(4)) . '.log';
        touch($this->log);
        $this->url = "http://127.0.0.1:{$port}";
        $env = ['CW_LOG' => $this->log, 'PATH' => (string) getenv('PATH')];
        $this->process = proc_open(
            [PHP_BINARY, '-S', "127.0.0.1:{$port}", __DIR__ . '/../servers/router.php'],
            [0 => ['file', '/dev/null', 'r'], 1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']],
            $pipes,
            null,
            $env,
        );
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

    /** @return list<array{method: string, uri: string, headers: array<string, string>, body: string}> */
    public function requests(): array
    {
        $lines = array_filter(explode("\n", (string) file_get_contents($this->log)));
        return array_values(array_map(fn (string $line) => json_decode($line, true), $lines));
    }

    public function stop(): void
    {
        if (is_resource($this->process)) {
            proc_terminate($this->process);
            proc_close($this->process);
        }
        @unlink($this->log);
    }
}
