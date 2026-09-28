<?php

declare(strict_types=1);

namespace cwt\console\controllers;

use Cronwatch\Craft\WatchCommand;
use craft\console\Controller;
use yii\console\ExitCode;

/** A command watched by its behavior, not the settings. */
final class BehavedController extends Controller
{
    public function behaviors(): array
    {
        return [...parent::behaviors(), 'cronwatch' => [
            'class' => WatchCommand::class,
            'schedule' => '0 4 * * *',
            'grace' => '20m',
            'actions' => ['index'],
        ]];
    }

    public function actionIndex(): int
    {
        return ExitCode::OK;
    }

    public function actionOther(): int
    {
        return ExitCode::OK;
    }
}
