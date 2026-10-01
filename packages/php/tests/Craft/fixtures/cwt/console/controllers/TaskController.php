<?php

declare(strict_types=1);

namespace cwt\console\controllers;

use Cronwatch\Cronwatch;
use Craft;
use craft\console\Controller;
use cwt\jobs\Flaky;
use cwt\jobs\Marked;
use yii\console\ExitCode;

/** Commands the settings list (config/cronwatch.php), and one to push jobs. */
final class TaskController extends Controller
{
    public function actionHello(): int
    {
        Cronwatch::current()?->log('hello from cwt');
        $this->stdout("hello\n");
        return ExitCode::OK;
    }

    public function actionFail(): int
    {
        return 3;
    }

    public function actionBoom(): int
    {
        throw new \RuntimeException('cwt command broke');
    }

    /** Runs cwt/task/inner, which throws, and carries on past it. */
    public function actionNested(): int
    {
        try {
            $this->run('inner');
        } catch (\RuntimeException $error) {
            $this->stdout("caught: {$error->getMessage()}\n");
        }
        return ExitCode::OK;
    }

    public function actionInner(): int
    {
        throw new \RuntimeException('cwt inner broke');
    }

    public function actionUnwatched(): int
    {
        return ExitCode::OK;
    }

    /** Pushes a flaky job that succeeds on attempt `succeedOn`, and a marked one. */
    public function actionPushCancelled(): int
    {
        Craft::$app->getQueue()->push(new \cwt\jobs\Cancelled());
        return ExitCode::OK;
    }

    public function actionPush(string $id, int $succeedOn = 1): int
    {
        Craft::$app->getQueue()->push(new Flaky(['key' => $id, 'succeedOn' => $succeedOn]));
        Craft::$app->getQueue()->push(new Marked());
        return ExitCode::OK;
    }
}
