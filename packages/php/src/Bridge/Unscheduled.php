<?php

declare(strict_types=1);

namespace Cronwatch\Bridge;

use Cronwatch\Cronwatch;

/**
 * Jobs a framework's scheduler no longer runs. A task taken out of the
 * schedule leaves its job in the store with the schedule it had, and a
 * check would report it missed from then on; so before a check, every job
 * the integration declared (known by its tag) that has a schedule and is
 * not declared in this process now is declared again without its schedule,
 * keeping its history and its other options. It is never reported missed,
 * and a missed alert already open is closed with a recovery.
 *
 * @internal For the framework integrations.
 */
final class Unscheduled
{
    /** The options kept when a job is declared again without its schedule. */
    private const KEPT = ['tags', 'grace', 'timeout', 'maxDuration', 'budget', 'failuresBeforeAlert'];

    /**
     * @param callable(\Throwable, string): void $report
     * @return list<string> the names declared again
     */
    public static function declare(Cronwatch $cw, string $tag, callable $report): array
    {
        $declared = [];
        foreach ($cw->definedJobs() as $definition) {
            $declared[(string) $definition->get('name')] = true;
        }
        $names = [];
        foreach ($cw->storedJobs() as $stored) {
            $definition = $stored->definition;
            $tags = $definition->get('tags');
            if (isset($declared[$stored->name]) || !is_array($tags) || !in_array($tag, $tags, true) || !$definition->has('schedule')) {
                continue;
            }
            $options = ['description' => ((string) ($definition->get('description') ?? 'A scheduled task')) . ' (no longer scheduled)'];
            foreach (self::KEPT as $key) {
                if ($definition->has($key)) {
                    $options[$key] = $definition->get($key);
                }
            }
            try {
                $cw->job($stored->name, $options);
                $names[] = $stored->name;
            } catch (\Throwable $error) {
                $report($error, "declaring {$stored->name}");
            }
        }
        return $names;
    }
}
