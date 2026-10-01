<?php

declare(strict_types=1);

namespace Cronwatch\Laravel;

use Illuminate\Contracts\Config\Repository;

/**
 * The settings whose keys 1.0 renamed to match the Symfony bundle's:
 * `table_prefix` (was `store.prefix`), `create_tables` (was
 * `store.create_tables`), `check.schedule` (was `schedule.check`) and
 * `check.frequency` (was `schedule.check_cron`). A config file published
 * before 1.0 still has the old keys; while it does, each is read in place
 * of its new key, with a deprecation notice once per process, through 1.x.
 * The package's own config file has only the new keys, so an old key that
 * is there came from the app.
 *
 * @internal
 */
final class Settings
{
    /** @var array<string, string> old key => new key, both under `cronwatch.` */
    public const RENAMED = [
        'store.prefix' => 'table_prefix',
        'store.create_tables' => 'create_tables',
        'schedule.check' => 'check.schedule',
        'schedule.check_cron' => 'check.frequency',
    ];

    /** @var array<string, true> the old keys already reported in this process */
    private static array $reported = [];

    public static function tablePrefix(Repository $config): string
    {
        $prefix = self::get($config, 'table_prefix', 'cronwatch_');
        return is_string($prefix) && $prefix !== '' ? $prefix : 'cronwatch_';
    }

    public static function createTables(Repository $config): bool
    {
        return self::get($config, 'create_tables', true) !== false;
    }

    public static function scheduleCheck(Repository $config): bool
    {
        return (bool) self::get($config, 'check.schedule', true);
    }

    public static function checkFrequency(Repository $config): string
    {
        $frequency = self::get($config, 'check.frequency', '*/5 * * * *');
        return is_string($frequency) && trim($frequency) !== '' ? trim($frequency) : '*/5 * * * *';
    }

    private static function get(Repository $config, string $key, mixed $default): mixed
    {
        $old = array_search($key, self::RENAMED, true);
        if (is_string($old) && $config->has("cronwatch.{$old}")) {
            if (!isset(self::$reported[$old])) {
                self::$reported[$old] = true;
                @trigger_error("The cronwatch.{$old} setting is deprecated and is read until 2.0; rename it to cronwatch.{$key} in config/cronwatch.php.", E_USER_DEPRECATED);
            }
            return $config->get("cronwatch.{$old}");
        }
        return $config->get("cronwatch.{$key}", $default);
    }

    /** For tests: report every old key again. */
    public static function forgetReported(): void
    {
        self::$reported = [];
    }
}
