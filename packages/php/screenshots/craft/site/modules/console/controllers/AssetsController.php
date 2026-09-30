<?php

namespace modules\console\controllers;

use craft\console\Controller;
use modules\Demo;
use yii\console\ExitCode;

/** craft app/assets/cleanup: unused image transforms and stale uploads, nightly. */
class AssetsController extends Controller
{
    public function actionCleanup(): int
    {
        $transforms = (int) Demo::get('transforms', 41);
        Demo::log("Removed {$transforms} unused image transforms (" . Demo::get('freed', '186 MB') . ')');
        Demo::log('Removed ' . (int) Demo::get('uploads', 3) . ' abandoned uploads older than 7 days');
        Demo::metric('transforms', $transforms);
        return ExitCode::OK;
    }
}
