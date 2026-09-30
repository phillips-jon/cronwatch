<?php

namespace modules\console\controllers;

use craft\console\Controller;
use modules\Demo;
use yii\console\ExitCode;

/** craft app/reports/send: the scheduled reports that are due, every 15 minutes. */
class ReportsController extends Controller
{
    public function actionSend(): int
    {
        $due = (array) Demo::get('due', []);
        if ($due === []) {
            Demo::log('No reports due');
        } else {
            foreach ($due as $report) {
                Demo::log("Sent {$report}");
            }
        }
        Demo::metric('sent', count($due));
        return ExitCode::OK;
    }
}
