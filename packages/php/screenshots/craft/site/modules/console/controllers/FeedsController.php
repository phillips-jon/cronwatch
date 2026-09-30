<?php

namespace modules\console\controllers;

use craft\console\Controller;
use modules\Demo;
use yii\console\ExitCode;

/** craft app/feeds/import: the supplier's product feed, hourly. */
class FeedsController extends Controller
{
    public function actionImport(): int
    {
        $url = 'https://feeds.example.com/northwind/products.xml';
        Demo::log("Fetching {$url}");
        if (Demo::get('down', false)) {
            Demo::log('Attempt 1 of 3: 503 Service Unavailable, retrying in 10s');
            Demo::log('Attempt 2 of 3: 503 Service Unavailable, retrying in 10s');
            Demo::log('Attempt 3 of 3: 503 Service Unavailable');
            throw new \RuntimeException("Supplier feed answered 503 Service Unavailable after 3 attempts ({$url})");
        }
        $products = (int) Demo::get('products', 1_284);
        $prices = (int) Demo::get('prices', 37);
        Demo::log("Parsed {$products} products");
        Demo::log("Updated {$prices} prices and " . (int) Demo::get('stock', 112) . ' stock levels');
        Demo::metric('products', $products);
        return ExitCode::OK;
    }
}
