<?php

declare(strict_types=1);

namespace Cronwatch\Laravel;

use Cronwatch\Env;
use Cronwatch\Js;
use Illuminate\Contracts\Config\Repository;
use Illuminate\Support\Env as LaravelEnv;

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

    /**
     * A token or secret from the config (`dashboard.token`, `cron_secret`),
     * or null when there is none. A string that is not blank (JavaScript's
     * whitespace) is the value, used as written. Any other value the config
     * gives (an empty or blank string, true, false) means none, with no
     * fallback. Only a config value of null (the key unset, or `env()` of a
     * variable that is unset) reads the variable, and then as Laravel's own
     * `env()` reads it, so `X=null`, `X=(null)`, `X=empty`, `X=true` and
     * `X=false` in .env are not a password (the raw environment holds them
     * as written). A cached config (`config:cache`) with
     * no value still reads a variable the process is given at run time.
     */
    public static function secret(Repository $config, string $key, string $variable): ?string
    {
        $value = $config->get("cronwatch.{$key}");
        if ($value === null && class_exists(LaravelEnv::class)) {
            $value = LaravelEnv::get($variable);
        }
        return is_string($value) && Js::trim($value) !== '' ? $value : null;
    }

    /**
     * Whether the raw environment holds a value for a variable that
     * secret() did not take (`CRONWATCH_TOKEN=null`, read by Laravel as
     * null): the library's own read of the variable must not be asked then.
     */
    public static function rawOnly(string $variable): bool
    {
        return Js::trim((string) Env::read($variable)) !== '';
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
