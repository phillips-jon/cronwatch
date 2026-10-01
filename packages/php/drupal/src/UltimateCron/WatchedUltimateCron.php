<?php

declare(strict_types=1);

namespace Drupal\cronwatch\UltimateCron;

use Drupal\cronwatch\Recorder;
use Drupal\ultimate_cron\UltimateCron;

/**
 * Ultimate Cron's cron service, with each cron run recorded as drupal:cron.
 *
 * CronServicePass makes the "cron" service this class when Ultimate Cron's
 * is there, so its constructor, arguments and method calls stay Ultimate
 * Cron's. run() is Ultimate Cron's (each enabled job that is due launched,
 * then core's queues unless Ultimate Cron runs them as jobs), with the whole
 * run recorded around it and the check after it, as WatchedCron does for
 * core's. Ultimate Cron takes no lock around a cron run, so neither does
 * this: two cron runs at once are two runs, and each job keeps its own lock.
 * The jobs' own runs are recorded by WatchedCronJob.
 *
 * CronWatch never stops cron: when the recorder cannot be had or fails,
 * cron runs as Ultimate Cron runs it.
 */
class WatchedUltimateCron extends UltimateCron {

  /**
   * {@inheritdoc}
   */
  public function run() {
    $recorder = Recorder::service();
    $recorder?->cronStarted();
    try {
      $result = parent::run();
    }
    catch (\Throwable $error) {
      $recorder?->cronFinished($error);
      throw $error;
    }
    if ($recorder !== NULL && $recorder->cronFinished(NULL)) {
      $recorder->checkAfterCron();
    }
    return $result;
  }

}
