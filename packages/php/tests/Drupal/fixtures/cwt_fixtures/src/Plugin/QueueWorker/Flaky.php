<?php

declare(strict_types=1);

namespace Drupal\cwt_fixtures\Plugin\QueueWorker;

use Cronwatch\Cronwatch;
use Drupal\Core\Queue\QueueWorkerBase;
use Drupal\Core\Queue\RequeueException;

/**
 * An item fails until its attempt number reaches its "succeed_on".
 *
 * Attempts are counted in state, by the item's "id". An item with
 * "requeue" asks for itself back with a RequeueException instead.
 *
 * @QueueWorker(
 *   id = "cwt_flaky",
 *   title = @Translation("CronWatch flaky queue"),
 *   cron = {"time" = 5}
 * )
 */
final class Flaky extends QueueWorkerBase {

  /**
   * {@inheritdoc}
   */
  public function processItem($data) {
    $state = \Drupal::state();
    $key = 'cwt.attempts.' . $data['id'];
    $attempt = (int) $state->get($key, 0) + 1;
    $state->set($key, $attempt);
    Cronwatch::current()?->log("item {$data['id']} attempt {$attempt}");
    if (!empty($data['requeue']) && $attempt === 1) {
      throw new RequeueException('not yet');
    }
    if ($attempt < (int) ($data['succeed_on'] ?? 1)) {
      throw new \RuntimeException("item {$data['id']} failed attempt {$attempt}");
    }
  }

}
