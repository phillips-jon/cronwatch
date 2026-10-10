<?php

declare(strict_types=1);

namespace Cronwatch\WordPress;

\defined('ABSPATH') || exit;

/**
 * Checks WP-Cron events for missed, failed, and stuck runs. Run it from the
 * system crontab every five minutes, so the check happens whether or not
 * anyone visits the site.
 */
final class Cli
{
    /**
     * Runs one check: looks for missed and stuck runs across every WP-Cron
     * event, sends alerts, retries undelivered ones, and prunes old runs.
     * Prints one line; --quiet prints nothing.
     *
     * ## EXAMPLES
     *
     *     wp cronwatch check
     *
     * @param list<string> $args
     * @param array<string, string> $assoc
     */
    public function check(array $args = [], array $assoc = []): void
    {
        try {
            $result = Plugin::check();
        } catch (\Throwable $error) {
            \WP_CLI::error('cronwatch: ' . $error->getMessage());
            return;
        }
        // "cronwatch: checked 3 jobs, sent 1 alert", as every port's check command prints it.
        \WP_CLI::log($result->summary());
    }
}
