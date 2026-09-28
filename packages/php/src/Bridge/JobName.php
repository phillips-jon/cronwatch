<?php

declare(strict_types=1);

namespace Cronwatch\Bridge;

use Cronwatch\Cronwatch;

/**
 * Job names made from what a framework's scheduler knows about a task: a
 * console command with its arguments, a class, a description. The rule is
 * the WordPress plugin's: runs of characters a name cannot hold become "-"
 * (with runs of "-" made one, so `--force` reads `-force`), and text that
 * had to be changed or cut gets "-" and the first eight hex
 * digits of its md5, so two different tasks never share a name. A class
 * name is written with dots for its backslashes first, which changes
 * nothing that needs telling apart (App\Jobs\Prune is App.Jobs.Prune).
 *
 * @internal For the framework integrations.
 */
final class JobName
{
    public const MAX = 120;

    /** A class name as a job name: App\Jobs\PruneUsers is App.Jobs.PruneUsers. */
    public static function ofClass(string $class): string
    {
        return self::clean(str_replace('\\', '.', ltrim($class, '\\')));
    }

    /** Any text as a job name. */
    public static function clean(string $text): string
    {
        $clean = (string) preg_replace(['/[^A-Za-z0-9._:-]+/', '/-{2,}/'], '-', $text);
        $clean = ltrim($clean, '._:-');
        if ($clean === $text && preg_match(Cronwatch::NAME_PATTERN, $clean) === 1) {
            return $clean;
        }
        $hash = '-' . substr(md5($text), 0, 8);
        $clean = rtrim(substr($clean, 0, self::MAX - strlen($hash)), '-');
        return ($clean === '' ? 'job' : $clean) . $hash;
    }
}
