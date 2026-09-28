<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Support;

/**
 * The built SDK in Node, for the tests that check this package against it
 * (tests/node/*.mjs). They need node on the PATH and the SDK built (`npm ci
 * && npm run build` at the repository root), and are skipped, with the
 * reason, without them.
 */
final class Node
{
    public const REPO = __DIR__ . '/../../../..';

    public static function unavailable(bool $sqlite = false): ?string
    {
        if (!function_exists('proc_open')) {
            return 'needs proc_open';
        }
        exec('command -v node 2>/dev/null', $out, $status);
        if ($status !== 0) {
            return 'node is not on the PATH';
        }
        if (!is_file(self::REPO . '/packages/sdk/dist/index.js')) {
            return 'packages/sdk/dist is not built: run `npm ci && npm run build` at the repository root';
        }
        if ($sqlite && !is_dir(self::REPO . '/node_modules/better-sqlite3')) {
            return "the SDK's SQLite driver is not installed: run `npm ci` at the repository root";
        }
        return null;
    }

    /** Runs a script in tests/node with these arguments, in UTC, and returns what it printed. */
    public static function run(string $script, string ...$args): string
    {
        $process = proc_open(
            ['node', __DIR__ . "/../node/{$script}", ...$args],
            [1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
            $pipes,
            null,
            [...getenv(), 'TZ' => 'UTC'],
        );
        if (!is_resource($process)) {
            throw new \RuntimeException("could not start node {$script}");
        }
        $out = (string) stream_get_contents($pipes[1]);
        $err = (string) stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        if (proc_close($process) !== 0) {
            throw new \RuntimeException("node {$script} " . implode(' ', array_slice($args, 0, 1)) . " failed: {$err}");
        }
        return $out;
    }
}
