<?php

declare(strict_types=1);

namespace Drupal\cronwatch\UltimateCron;

use Drupal\cronwatch\Recorder;
use Drupal\ultimate_cron\Entity\CronJob;

/**
 * Ultimate Cron's job entity, with each run of its callback recorded.
 *
 * cronwatch_entity_type_alter() makes the ultimate_cron_job entity type this
 * class when it is Ultimate Cron's own. CronJob::run() takes the job's lock
 * (a job still running, or locked, is not run at all, and so is no run
 * here), starts Ultimate Cron's log entry, calls invokeCallback(), catches
 * whatever it throws into that log entry, and lets go of the lock.
 * invokeCallback() is the one place a run happens, whoever launched it (a
 * cron run, the "Run" button, `drush cron:run <job>`), so it is recorded
 * here: started before the callback, finished after it, failed with what it
 * threw, which is thrown on for Ultimate Cron to log as before.
 *
 * CronWatch never stops a job: when the recorder cannot be had or fails,
 * the job runs as Ultimate Cron runs it.
 */
class WatchedCronJob extends CronJob {

  /**
   * {@inheritdoc}
   */
  protected function invokeCallback() {
    $recorder = Recorder::service();
    if ($recorder === NULL) {
      parent::invokeCallback();
      return;
    }
    $key = $recorder->ultimateJobStarted($this);
    try {
      parent::invokeCallback();
    }
    catch (\Throwable $error) {
      $recorder->ultimateJobFinished($key, (string) $this->id(), $error);
      throw $error;
    }
    $recorder->ultimateJobFinished($key, (string) $this->id(), NULL);
  }

}
