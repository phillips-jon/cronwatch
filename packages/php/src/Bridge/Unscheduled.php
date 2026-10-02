<?php

declare(strict_types=1);

namespace Cronwatch\Bridge;

use Cronwatch\Cronwatch;

/**
 * Jobs a framework's scheduler no longer runs. A task taken out of the
 * schedule leaves its job in the store with the schedule it had, and a
 * check would report it missed from then on; so before a check, every job
 * this app declared that has a schedule and is not declared in this process
 * now is declared again without its schedule, keeping its history and its
 * other options. It is never reported missed, and a missed alert already
 * open is closed with a recovery.
 *
 * Which jobs are this app's is told by two tags: the integration's
 * ("laravel-scheduler") and the app's own under it
 * ("laravel-scheduler:<app>", see appTag()), so two apps sharing one store
 * and table prefix never declare each other's jobs without a schedule. A
 * job tagged by an earlier version, with the integration's tag and no app
 * tag, is taken for this app's (and given its tag) only while no other
 * app's tag is in the store; with another app there it is left alone,
 * since it could be either's.
 *
 * @internal For the framework integrations.
 */
final class Unscheduled
{
    /** The options kept when a job is declared again without its schedule. */
    private const KEPT = ['tags', 'grace', 'timeout', 'maxDuration', 'budget', 'floor', 'failuresBeforeAlert'];

    /**
     * The tag that names the app under an integration's tag: "<tag>:<app>",
     * the app's name lowercased, with anything but letters, digits, ".", "_"
     * and "-" made "-". A name that is empty once cleaned, or longer than 48
     * characters, is cut and given 8 hex characters of its MD5, so two names
     * never share a tag.
     */
    public static function appTag(string $tag, string $app): string
    {
        $slug = trim((string) preg_replace('/[^a-z0-9._-]+/', '-', strtolower(trim($app))), '-');
        if ($slug === '' || strlen($slug) > 48) {
            $slug = ltrim(substr($slug, 0, 39) . '-', '-') . substr(md5($app), 0, 8);
        }
        return "{$tag}:{$slug}";
    }

    /**
     * @param string $tag the integration's tag
     * @param string $appTag this app's tag under it (appTag())
     * @param callable(\Throwable, string): void $report
     * @return list<string> the names declared again
     */
    public static function declare(Cronwatch $cw, string $tag, string $appTag, callable $report): array
    {
        $declared = [];
        foreach ($cw->definedJobs() as $definition) {
            $declared[(string) $definition->get('name')] = true;
        }
        $stored = $cw->storedJobs();
        $under = $tag . ':';
        $otherApp = false;
        foreach ($stored as $job) {
            foreach (self::tags($job->definition->get('tags')) as $one) {
                $otherApp = $otherApp || (str_starts_with($one, $under) && $one !== $appTag);
            }
        }
        $names = [];
        foreach ($stored as $job) {
            $definition = $job->definition;
            $tags = self::tags($definition->get('tags'));
            if (isset($declared[$job->name]) || !$definition->has('schedule')) {
                continue;
            }
            $ours = in_array($appTag, $tags, true);
            $legacy = !$ours && !$otherApp && in_array($tag, $tags, true)
                && array_filter($tags, fn (string $one) => str_starts_with($one, $under)) === [];
            if (!$ours && !$legacy) {
                continue;
            }
            $options = ['description' => ((string) ($definition->get('description') ?? 'A scheduled task')) . ' (no longer scheduled)'];
            foreach (self::KEPT as $key) {
                if ($definition->has($key)) {
                    $options[$key] = $definition->get($key);
                }
            }
            if ($legacy) {
                $options['tags'] = [...$tags, $appTag];
            }
            try {
                $cw->job($job->name, $options);
                $names[] = $job->name;
            } catch (\Throwable $error) {
                $report($error, "declaring {$job->name}");
            }
        }
        return $names;
    }

    /** @return list<string> */
    private static function tags(mixed $tags): array
    {
        return is_array($tags) ? array_values(array_filter($tags, 'is_string')) : [];
    }
}
