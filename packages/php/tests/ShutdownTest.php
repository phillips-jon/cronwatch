<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Store\SqliteStore;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * A run in progress when its process ends (exit() inside the job, or a
 * fatal error such as memory running out, which no catch sees) is recorded
 * as a failed run by the client's shutdown hook, as the Python port records
 * a KeyboardInterrupt, so no run is left running to be reported stuck later.
 */
final class ShutdownTest extends TestCase
{
    public static function endings(): iterable
    {
        yield 'exit()' => ['exit', 3, 'Interrupted: the process exited during the run'];
        yield 'memory running out' => ['memory', 255, 'Interrupted: Fatal error: Allowed memory size of 67108864 bytes exhausted'];
    }

    #[DataProvider('endings')]
    public function testARunEndedWithItsProcessIsRecordedAsFailed(string $mode, int $status, string $error): void
    {
        if (!function_exists('proc_open')) {
            $this->markTestSkipped('needs proc_open');
        }
        $file = sys_get_temp_dir() . '/cronwatch-shutdown-' . getmypid() . '-' . bin2hex(random_bytes(4)) . '.db';
        try {
            $process = proc_open([PHP_BINARY, '-d', 'display_errors=0', __DIR__ . '/workers/interrupted.php', $mode, $file], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
            stream_get_contents($pipes[1]);
            stream_get_contents($pipes[2]);
            fclose($pipes[1]);
            fclose($pipes[2]);
            $this->assertSame($status, proc_close($process));
            $run = (new SqliteStore($file))->listRuns('nightly', 1)[0];
            $this->assertSame('failed', $run->status);
            $this->assertStringStartsWith($error, $run->error);
            $this->assertSame('started', $run->output);
            $this->assertNotNull($run->finishedAt);
        } finally {
            foreach ([$file, "{$file}-wal", "{$file}-shm"] as $f) {
                @unlink($f);
            }
        }
    }
}
