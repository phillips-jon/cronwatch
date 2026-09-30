<?php

declare(strict_types=1);

namespace Drupal\cwt_twice\Hook;

use Cronwatch\Cronwatch;
use Drupal\Core\Hook\Attribute\Hook;

/**
 * Two implementations of hook_cron in one module, as Drupal 11.1 allows.
 *
 * The first throws while the state key cwt.twice_mode is "throw".
 */
final class CronHooks {

  /**
   * Implements hook_cron().
   */
  #[Hook('cron')]
  public function first(): void {
    Cronwatch::current()?->log('first ran');
    if (\Drupal::state()->get('cwt.twice_mode', 'ok') === 'throw') {
      throw new \RuntimeException('the first cron hook broke');
    }
  }

  /**
   * Implements hook_cron().
   */
  #[Hook('cron')]
  public function second(): void {
    Cronwatch::current()?->log('second ran');
  }

}
