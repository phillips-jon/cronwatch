<?php

declare(strict_types=1);

namespace Drupal\cronwatch;

use Drupal\Component\Utility\Timer;
use Drupal\Core\Cron;
use Drupal\Core\Utility\Error;
use Psr\Log\NullLogger;

/**
 * Drupal's cron service, with each run and each hook_cron recorded.
 *
 * CronwatchServiceProvider makes the "cron" service this class, so its
 * constructor and arguments are core's, whichever core it is. run() is
 * core's, with the whole run recorded around it (only when this process
 * took the cron lock) and the check after it; invokeCronHandlers() is
 * core's, line for line (the same order, the same logging, the same
 * \Exception caught so one module cannot stop the others), with each
 * module's hook_cron recorded as a run of its own. A module with several
 * implementations (Drupal 11.1 and newer, #[Hook('cron')] on more than one
 * method) is one run: started before its first, finished after its last,
 * failed with the first exception any of them threw. An \Error, which core
 * does not catch, is recorded and thrown on, as core throws it.
 *
 * CronWatch never stops cron: when the recorder cannot be had or fails,
 * cron runs as core runs it.
 */
class WatchedCron extends Cron {

  /**
   * {@inheritdoc}
   */
  public function run() {
    $recorder = self::recorder();
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

  /**
   * {@inheritdoc}
   */
  protected function invokeCronHandlers() {
    $recorder = self::recorder();
    if ($recorder === NULL) {
      parent::invokeCronHandlers();
      return;
    }
    $recorder->cronStarted();

    // How many implementations each module has, so its run ends after the last.
    $remaining = [];
    $this->moduleHandler->invokeAllWith('cron', function (callable $hook, string $module) use (&$remaining): void {
      $remaining[$module] = ($remaining[$module] ?? 0) + 1;
    });
    $runs = [];

    $module_previous = '';

    // If detailed logging isn't enabled, don't log individual execution times.
    $time_logging_enabled = \Drupal::config('system.cron')->get('logging');
    $logger = $time_logging_enabled ? $this->logger : new NullLogger();

    // Iterate through the modules calling their cron handlers (if any):
    $this->moduleHandler->invokeAllWith('cron', function (callable $hook, string $module) use (&$module_previous, &$remaining, &$runs, $logger, $recorder) {
      if (!$module_previous) {
        $logger->info('Starting execution of @module_cron().', [
          '@module' => $module,
        ]);
      }
      else {
        $logger->info('Starting execution of @module_cron(), execution of @module_previous_cron() took @time.', [
          '@module' => $module,
          '@module_previous' => $module_previous,
          '@time' => Timer::read('cron_' . $module_previous) . 'ms',
        ]);
      }
      Timer::start('cron_' . $module);
      if (!array_key_exists($module, $runs)) {
        $runs[$module] = ['key' => $recorder->hookStarted($module), 'error' => NULL];
      }

      // Do not let an exception thrown by one module disturb another.
      try {
        $hook();
      }
      catch (\Exception $e) {
        $runs[$module]['error'] ??= $e;
        Error::logException($this->logger, $e);
      }
      catch (\Throwable $e) {
        // Core lets an \Error end the cron run; it is recorded first.
        $recorder->hookFinished($runs[$module]['key'], $module, $runs[$module]['error'] ?? $e);
        throw $e;
      }
      $remaining[$module] = ($remaining[$module] ?? 1) - 1;
      if ($remaining[$module] <= 0) {
        $recorder->hookFinished($runs[$module]['key'], $module, $runs[$module]['error']);
      }

      Timer::stop('cron_' . $module);
      $module_previous = $module;
    });
    if ($module_previous) {
      $logger->info('Execution of @module_previous_cron() took @time.', [
        '@module_previous' => $module_previous,
        '@time' => Timer::read('cron_' . $module_previous) . 'ms',
      ]);
    }
  }

  /**
   * The recorder, or null when it cannot be had (a broken container).
   */
  private static function recorder(): ?Recorder {
    try {
      $recorder = \Drupal::service('cronwatch.recorder');
      return $recorder instanceof Recorder ? $recorder : NULL;
    }
    catch (\Throwable) {
      return NULL;
    }
  }

}
