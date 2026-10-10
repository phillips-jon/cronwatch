<?php

/**
 * @file
 * Hooks CronWatch invokes.
 */

declare(strict_types=1);

/**
 * @addtogroup hooks
 * @{
 */

/**
 * Changes the alert channels.
 *
 * The settings' channels (email, Slack, a webhook) are in the list; add any
 * of the library's (Cronwatch\Alerts\...) or a callable taking the
 * Cronwatch\Alert. With none, alerts go to the site's log.
 *
 * @param list<mixed> $channels
 *   The channels.
 */
function hook_cronwatch_alerts_alter(array &$channels): void {
  $channels[] = new \Cronwatch\Alerts\Discord(getenv('DISCORD_WEBHOOK_URL'));
}

/**
 * Changes a job's options before it is declared.
 *
 * @param array<string, mixed> $options
 *   The job's options: schedule, grace, timeout, maxDuration, budget,
 *   floor, expect, failuresBeforeAlert, description, and tags.
 * @param string $name
 *   The job's name: drupal:cron, drupal:<module>, or drupal:queue:<worker>.
 * @param array<string, string> $context
 *   What the job is: "kind" (cron, module, queue, or ultimate_cron), and
 *   "module" or "queue", or for an Ultimate Cron job "job" (its id) and
 *   "module".
 */
function hook_cronwatch_job_options_alter(array &$options, string $name, array $context): void {
  if ($name === 'drupal:search') {
    // Indexing a large site takes a while.
    $options['timeout'] = '2h';
  }
}

/**
 * @} End of "addtogroup hooks".
 */
