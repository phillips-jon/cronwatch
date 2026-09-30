<?php

namespace modules\jobs;

use craft\queue\BaseJob;
use modules\Demo;

/** Stock levels from the warehouse's API, queued every half hour. */
class SyncInventory extends BaseJob
{
    public function execute($queue): void
    {
        Demo::log('GET https://warehouse.example.com/v2/stock?changed_since=30m');
        if (Demo::get('down', false)) {
            throw new \RuntimeException('Warehouse API timed out after 30 seconds (GET https://warehouse.example.com/v2/stock)');
        }
        $levels = (int) Demo::get('levels', 214);
        Demo::log("Updated {$levels} stock levels across 3 locations");
        Demo::metric('levels', $levels);
    }

    protected function defaultDescription(): ?string
    {
        return 'Syncing inventory';
    }
}
