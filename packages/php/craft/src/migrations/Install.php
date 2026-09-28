<?php

declare(strict_types=1);

namespace Cronwatch\Craft\migrations;

use Cronwatch\Craft\Storage;
use craft\db\Migration;

/**
 * The library's three tables, made by the library's store with the CREATE
 * text every port uses, through its own connection to Craft's database;
 * IF NOT EXISTS, so tables another port already made are kept. Dropped when
 * the plugin is uninstalled.
 */
final class Install extends Migration
{
    public function safeUp(): bool
    {
        Storage::store($this->db)->init();
        return true;
    }

    public function safeDown(): bool
    {
        Storage::drop($this->db);
        return true;
    }
}
