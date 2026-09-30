<?php
// What the screenshot site watches: the commands its crontab runs and two queue jobs.
return [
    'commands' => [
        'resave/entries' => ['schedule' => '0 3 * * *', 'timezone' => 'Europe/London', 'grace' => '30m'],
        'app/reports/send' => ['schedule' => '*/15 * * * *', 'grace' => '5m', 'name' => 'send-reports'],
        'app/feeds/import' => ['schedule' => '20 * * * *', 'description' => 'Imports the supplier product feed'],
        'app/rates/fetch' => ['schedule' => '5 * * * *', 'name' => 'exchange-rates'],
        'app/sitemap/rebuild' => ['schedule' => '45 * * * *'],
        'app/assets/cleanup' => ['schedule' => '30 2 * * *', 'timezone' => 'Europe/London'],
    ],
    'queueJobs' => [
        modules\jobs\SyncInventory::class => ['failuresBeforeAlert' => 3],
        modules\jobs\SendNewsletter::class => true,
    ],
];
