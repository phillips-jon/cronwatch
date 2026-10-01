<?php

declare(strict_types=1);

namespace Drupal\cwt_fixtures;

use Cronwatch\Cronwatch;

/**
 * The callback of an Ultimate Cron job that is not a hook_cron, made by the
 * tests that need one.
 */
final class Nightly {

  /**
   * Ultimate Cron calls a callback with the job.
   */
  public static function run(object $job): void {
    Cronwatch::current()?->log('nightly ran');
  }

}
