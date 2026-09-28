<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * `vendor/bin/cronwatch`: one check, for a crontab line, with no script of
 * the app's own.
 *
 *     0-59/5 * * * * cd /var/www/app && vendor/bin/cronwatch check
 *
 * It finds the app's client in a bootstrap file: a PHP file that returns
 * the Cronwatch client, its jobs declared (or a callable that returns it).
 * The file is `--bootstrap <path>`, else CRONWATCH_BOOTSTRAP, else the first
 * of cronwatch.php and config/cronwatch.php in the working directory. The
 * Composer autoloader is loaded first, so the file can use the app's
 * classes. The check prints the line every port's check command prints and
 * exits 0, or prints what went wrong to standard error and exits 1.
 */
final class Cli
{
    private const USAGE = <<<'TEXT'
        Usage: cronwatch check [--bootstrap <file>] [--quiet]

        Checks every job for missed and stuck runs, sends alerts, retries
        undelivered ones and prunes old runs. Run it from cron every few minutes.

        The bootstrap file returns the app's Cronwatch client, its jobs declared
        (or a callable returning it). Default: CRONWATCH_BOOTSTRAP, else
        cronwatch.php, else config/cronwatch.php, in the working directory.
        TEXT;

    /** @var resource */
    private $out;
    /** @var resource */
    private $err;

    /**
     * @param resource|null $out
     * @param resource|null $err
     */
    public function __construct(private readonly string $cwd, $out = null, $err = null)
    {
        $this->out = $out ?? STDOUT;
        $this->err = $err ?? STDERR;
    }

    /**
     * Runs the command line (without the program name) and returns the exit status.
     *
     * @param list<string> $argv
     */
    public function run(array $argv): int
    {
        try {
            [$command, $bootstrap, $quiet] = self::parse($argv);
        } catch (\InvalidArgumentException $error) {
            fwrite($this->err, "cronwatch: {$error->getMessage()}\n\n" . self::USAGE . "\n");
            return 2;
        }
        if ($command === 'help') {
            fwrite($this->out, self::USAGE . "\n");
            return 0;
        }
        if ($command === 'version') {
            fwrite($this->out, 'cronwatch ' . Cronwatch::VERSION . "\n");
            return 0;
        }
        try {
            $client = $this->client($bootstrap);
            $result = $client->check();
        } catch (\Throwable $error) {
            $what = $error instanceof \UnexpectedValueException ? '' : Output::errorName($error) . ': ';
            fwrite($this->err, "cronwatch: {$what}{$error->getMessage()}\n");
            return 1;
        }
        if (!$quiet) {
            fwrite($this->out, $result->summary() . "\n");
        }
        return 0;
    }

    /**
     * @param list<string> $argv
     * @return array{string, ?string, bool}
     */
    private static function parse(array $argv): array
    {
        $command = null;
        $bootstrap = null;
        $quiet = false;
        for ($i = 0; $i < count($argv); $i++) {
            $arg = $argv[$i];
            if ($arg === '--bootstrap' || $arg === '-b') {
                $bootstrap = $argv[++$i] ?? throw new \InvalidArgumentException("{$arg} needs a file");
            } elseif (str_starts_with($arg, '--bootstrap=')) {
                $bootstrap = substr($arg, 12);
            } elseif ($arg === '--quiet' || $arg === '-q') {
                $quiet = true;
            } elseif ($arg === '--help' || $arg === '-h') {
                $command = 'help';
            } elseif ($arg === '--version' || $arg === '-V') {
                $command = 'version';
            } elseif ($command === null && in_array($arg, ['check', 'help', 'version'], true)) {
                $command = $arg;
            } else {
                throw new \InvalidArgumentException("unknown argument \"{$arg}\"");
            }
        }
        return [$command ?? 'help', $bootstrap, $quiet];
    }

    /** The client the bootstrap file returns. */
    public function client(?string $bootstrap = null): Cronwatch
    {
        $file = $this->bootstrapFile($bootstrap);
        $client = (static fn (string $__file) => require $__file)($file);
        if ($client instanceof \Closure || (is_callable($client) && !$client instanceof Cronwatch)) {
            $client = $client();
        }
        if (is_array($client)) {
            throw new \UnexpectedValueException("{$file} returns an array, which looks like a framework's settings file: it must return a Cronwatch client (or a callable that returns one); pass --bootstrap <file> to use another");
        }
        if (!$client instanceof Cronwatch) {
            throw new \UnexpectedValueException("{$file} must return a Cronwatch client (or a callable that returns one), not " . get_debug_type($client));
        }
        return $client;
    }

    private function bootstrapFile(?string $given): string
    {
        $given ??= Env::read('CRONWATCH_BOOTSTRAP');
        if ($given !== null && $given !== '') {
            $path = str_starts_with($given, '/') || preg_match('/^[A-Za-z]:[\\\\\/]/', $given) === 1 ? $given : "{$this->cwd}/{$given}";
            if (!is_file($path)) {
                throw new \UnexpectedValueException("no bootstrap file at {$path}");
            }
            return $path;
        }
        if (is_file("{$this->cwd}/cronwatch.php")) {
            return "{$this->cwd}/cronwatch.php";
        }
        if (is_file("{$this->cwd}/config/cronwatch.php")) {
            // In a Laravel or Craft app that file is the framework's settings
            // array, which calls the framework's own helpers (env()), so it is
            // never loaded here: the framework's command runs the check.
            foreach (['artisan' => 'php artisan cronwatch:check', 'craft' => 'php craft cronwatch/check'] as $entry => $command) {
                if (is_file("{$this->cwd}/{$entry}")) {
                    throw new \UnexpectedValueException("config/cronwatch.php here is this app's settings file, not a bootstrap: run `{$command}` instead, or pass --bootstrap <file>");
                }
            }
            return "{$this->cwd}/config/cronwatch.php";
        }
        throw new \UnexpectedValueException("no bootstrap file: pass --bootstrap <file>, set CRONWATCH_BOOTSTRAP, or add cronwatch.php to {$this->cwd}");
    }
}
