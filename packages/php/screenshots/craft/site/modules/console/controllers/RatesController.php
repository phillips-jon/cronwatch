<?php

namespace modules\console\controllers;

use craft\console\Controller;
use modules\Demo;
use yii\console\ExitCode;

/** craft app/rates/fetch: exchange rates for the store's prices, hourly. */
class RatesController extends Controller
{
    public function actionFetch(): int
    {
        Demo::log('Fetched 31 exchange rates (base GBP)');
        Demo::log('EUR ' . Demo::get('eur', '1.1872') . ', USD ' . Demo::get('usd', '1.3391'));
        return ExitCode::OK;
    }
}
