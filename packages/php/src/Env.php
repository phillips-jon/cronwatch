<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * The environment, read in one place (the SDK reads NODE_ENV). PHP has no
 * single convention, so the first of CRONWATCH_ENV, APP_ENV (Laravel,
 * Symfony, Craft) and WP_ENVIRONMENT_TYPE (WordPress) that is set is used,
 * from getenv(), $_ENV or $_SERVER, since frameworks that read a .env file
 * put its values in one of those. It only decides whether the in-memory
 * store warns that it forgets on restart.
 *
 * @internal
 */
final class Env
{
    private const VARIABLES = ['CRONWATCH_ENV', 'APP_ENV', 'WP_ENVIRONMENT_TYPE'];

    public static function read(string $name): ?string
    {
        $value = getenv($name);
        if (is_string($value) && $value !== '') {
            return $value;
        }
        foreach ([$_ENV, $_SERVER] as $source) {
            if (isset($source[$name]) && is_string($source[$name]) && $source[$name] !== '') {
                return $source[$name];
            }
        }
        return null;
    }

    public static function environment(): ?string
    {
        foreach (self::VARIABLES as $name) {
            $value = self::read($name);
            if ($value !== null) {
                return strtolower(trim($value));
            }
        }
        return null;
    }

    public static function isProduction(): bool
    {
        return in_array(self::environment(), ['production', 'prod'], true);
    }

    public static function isDevelopment(): bool
    {
        return in_array(self::environment(), ['development', 'dev', 'local', 'test', 'testing'], true);
    }
}
