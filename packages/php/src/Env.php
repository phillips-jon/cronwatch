<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * The environment, read in one place (the SDK reads NODE_ENV). PHP has no
 * single convention, so the first of CRONWATCH_ENV, APP_ENV (Laravel,
 * Symfony, Craft) and WP_ENVIRONMENT_TYPE (WordPress) whose value, trimmed,
 * is not empty is used, lowercased (a value of only spaces counts as
 * unset), from getenv(), $_ENV or $_SERVER, since frameworks that read a
 * .env file put its values in one of those; failing those, what a framework
 * integration names with setFallback() (the WordPress plugin gives
 * wp_get_environment_type(), which also reads the constant of that name).
 * "development", "dev", "local", "test" and "testing" are development (the
 * SDK's NODE_ENV "development" and "test", and Laravel's and Symfony's own
 * names); "production" and "prod" are production.
 *
 * It decides whether the in-memory store warns that it forgets, and whether
 * the dashboard makes a development token when none is configured.
 *
 * @internal
 */
final class Env
{
    private const VARIABLES = ['CRONWATCH_ENV', 'APP_ENV', 'WP_ENVIRONMENT_TYPE'];

    private static ?\Closure $fallback = null;

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

    /** What names the environment when no variable does (a framework's own setting), or null for nothing. */
    public static function setFallback(?callable $read): void
    {
        self::$fallback = $read === null ? null : \Closure::fromCallable($read);
    }

    public static function environment(): ?string
    {
        foreach (self::VARIABLES as $name) {
            // A value of only spaces counts as unset, and the next one is read.
            $value = Js::trim((string) self::read($name));
            if ($value !== '') {
                return strtolower($value);
            }
        }
        if (self::$fallback !== null) {
            try {
                $value = (self::$fallback)();
            } catch (\Throwable) {
                return null;
            }
            return is_string($value) && Js::trim($value) !== '' ? strtolower(Js::trim($value)) : null;
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
