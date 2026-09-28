<?php

declare(strict_types=1);

namespace Cronwatch\Craft\console\controllers;

use Cronwatch\Craft\Plugin;
use craft\console\Controller;
use yii\console\ExitCode;

/**
 * `craft cronwatch/check`, for the host's crontab: finds missed and stuck
 * runs and sends what alerts are due, after declaring the settings' jobs.
 * Prints the line every CronWatch port prints; anything that goes wrong is
 * one line on standard error and exit status 1, so cron mails it.
 */
final class CheckController extends Controller
{
    public $defaultAction = 'index';

    public function actionIndex(): int
    {
        try {
            $result = Plugin::getInstance()->getRecorder()->check();
        } catch (\Throwable $error) {
            $this->stderr('cronwatch: ' . $error->getMessage() . "\n");
            return ExitCode::UNSPECIFIED_ERROR;
        }
        $this->stdout($result->summary() . "\n");
        return ExitCode::OK;
    }
}
