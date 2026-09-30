<?php

namespace modules\console\controllers;

use craft\console\Controller;
use modules\Demo;
use yii\console\ExitCode;

/** craft app/sitemap/rebuild: the XML sitemap and the product feed for search engines, hourly. */
class SitemapController extends Controller
{
    public function actionRebuild(): int
    {
        $urls = (int) Demo::get('urls', 2_406);
        Demo::log("Wrote sitemap.xml: {$urls} URLs");
        Demo::log('Wrote google-products.xml: ' . (int) Demo::get('products', 1_284) . ' items');
        Demo::metric('urls', $urls);
        return ExitCode::OK;
    }
}
