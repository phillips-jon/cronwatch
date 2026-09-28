<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Cli;
use Cronwatch\Tests\Support\Clock;
use PHPUnit\Framework\TestCase;

/**
 * `vendor/bin/cronwatch check`: the bootstrap file is found and its client
 * checked, the line is the gem's rake task's and the Python command's, and
 * a failure is a message on standard error and exit status 1.
 */
final class CliTest extends TestCase
{
    private string $dir;

    protected function setUp(): void
    {
        $this->dir = sys_get_temp_dir() . '/cronwatch-php-cli-' . getmypid() . '-' . bin2hex(random_bytes(4));
        mkdir("{$this->dir}/config", 0777, true);
    }

    protected function tearDown(): void
    {
        foreach (["{$this->dir}/config/cronwatch.php", "{$this->dir}/cronwatch.php", "{$this->dir}/other.php", "{$this->dir}/cw.db", "{$this->dir}/artisan", "{$this->dir}/craft"] as $file) {
            @unlink($file);
        }
        @rmdir("{$this->dir}/config");
        @rmdir($this->dir);
    }

    /** A bootstrap file declaring `$jobs` hourly jobs on a SQLite file, its clock `$hours` hours after T0. */
    private function bootstrap(string $name, int $jobs, int $hours = 0, bool $callable = false): void
    {
        $now = Clock::T0 + $hours * Clock::HOUR;
        $declare = '';
        for ($i = 1; $i <= $jobs; $i++) {
            $declare .= "\$cw->job('job-{$i}', ['schedule' => '0 * * * *']);\n";
        }
        $body = "\$cw = new Cronwatch\\Cronwatch(store: new Cronwatch\\Store\\SqliteStore('{$this->dir}/cw.db'), alerts: [fn () => null], cronSecret: false, now: fn () => {$now});\n{$declare}";
        $php = $callable ? "<?php\nreturn function () {\n{$body}return \$cw;\n};\n" : "<?php\n{$body}return \$cw;\n";
        file_put_contents("{$this->dir}/{$name}", $php);
    }

    /** @return array{int, string, string} the exit status, standard output and standard error */
    private function cli(array $argv): array
    {
        $out = fopen('php://memory', 'w+');
        $err = fopen('php://memory', 'w+');
        $status = (new Cli($this->dir, $out, $err))->run($argv);
        rewind($out);
        rewind($err);
        return [$status, (string) stream_get_contents($out), (string) stream_get_contents($err)];
    }

    public function testCheckFindsCronwatchPhpAndPrintsTheLine(): void
    {
        $this->bootstrap('cronwatch.php', 3);
        $this->assertSame([0, "cronwatch: checked 3 jobs, sent 0 alerts\n", ''], $this->cli(['check']));
        // Two hours on, each hourly job is missed: one alert each, the two not declared here checked from the store.
        $this->bootstrap('cronwatch.php', 1, 2);
        $this->assertSame([0, "cronwatch: checked 3 jobs, sent 3 alerts\n", ''], $this->cli(['check']));
    }

    public function testCheckFindsConfigCronwatchPhpAndACallable(): void
    {
        $this->bootstrap('config/cronwatch.php', 1, 0, callable: true);
        $this->assertSame([0, "cronwatch: checked 1 job, sent 0 alerts\n", ''], $this->cli(['check']));
    }

    public function testALaravelOrCraftSettingsFileIsNeverLoadedAndTheFrameworkCommandIsNamed(): void
    {
        // A framework settings file calls the framework's helpers, so loading it here would fail.
        file_put_contents("{$this->dir}/config/cronwatch.php", "<?php\nreturn ['store' => env('CRONWATCH_STORE')];\n");
        foreach (['artisan' => 'php artisan cronwatch:check', 'craft' => 'php craft cronwatch/check'] as $entry => $command) {
            file_put_contents("{$this->dir}/{$entry}", "<?php\n");
            $this->assertSame([1, '', "cronwatch: config/cronwatch.php here is this app's settings file, not a bootstrap: run `{$command}` instead, or pass --bootstrap <file>\n"], $this->cli(['check']));
            unlink("{$this->dir}/{$entry}");
        }
        // Elsewhere, a found file that returns an array says so.
        file_put_contents("{$this->dir}/config/cronwatch.php", "<?php\nreturn ['store' => 'sqlite'];\n");
        $this->assertSame([1, '', "cronwatch: {$this->dir}/config/cronwatch.php returns an array, which looks like a framework's settings file: it must return a Cronwatch client (or a callable that returns one); pass --bootstrap <file> to use another\n"], $this->cli(['check']));
    }

    public function testTheBootstrapFileCanBeNamed(): void
    {
        $this->bootstrap('other.php', 2);
        $this->assertSame([0, "cronwatch: checked 2 jobs, sent 0 alerts\n", ''], $this->cli(['check', '--bootstrap', 'other.php']));
        $this->assertSame([0, '', ''], $this->cli(['check', "--bootstrap={$this->dir}/other.php", '--quiet']));
        putenv('CRONWATCH_BOOTSTRAP=other.php');
        try {
            $this->assertSame([0, "cronwatch: checked 2 jobs, sent 0 alerts\n", ''], $this->cli(['check']));
        } finally {
            putenv('CRONWATCH_BOOTSTRAP');
        }
    }

    public function testFailuresGoToStandardErrorWithExitStatusOne(): void
    {
        [$status, $out, $err] = $this->cli(['check']);
        $this->assertSame([1, ''], [$status, $out]);
        $this->assertStringStartsWith("cronwatch: no bootstrap file: pass --bootstrap <file>, set CRONWATCH_BOOTSTRAP, or add cronwatch.php to {$this->dir}", $err);
        file_put_contents("{$this->dir}/cronwatch.php", "<?php\nreturn 42;\n");
        $this->assertSame([1, '', "cronwatch: {$this->dir}/cronwatch.php must return a Cronwatch client (or a callable that returns one), not int\n"], $this->cli(['check']));
        file_put_contents("{$this->dir}/cronwatch.php", "<?php\nthrow new DomainException('no database');\n");
        $this->assertSame([1, '', "cronwatch: DomainException: no database\n"], $this->cli(['check']));
        [$status, , $err] = $this->cli(['check', '--nope']);
        $this->assertSame(2, $status);
        $this->assertStringStartsWith("cronwatch: unknown argument \"--nope\"\n\nUsage: cronwatch check", $err);
    }

    public function testTheBinScriptRunsTheCheck(): void
    {
        $this->bootstrap('cronwatch.php', 1);
        $process = proc_open([PHP_BINARY, __DIR__ . '/../bin/cronwatch', 'check'], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, $this->dir);
        $out = stream_get_contents($pipes[1]);
        $err = stream_get_contents($pipes[2]);
        $this->assertSame(0, proc_close($process), $err);
        $this->assertSame("cronwatch: checked 1 job, sent 0 alerts\n", $out);
        $this->assertSame('cronwatch ' . \Cronwatch\Cronwatch::VERSION . "\n", shell_exec(escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg(__DIR__ . '/../bin/cronwatch') . ' --version'));
    }
}
