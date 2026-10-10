<?php

declare(strict_types=1);

namespace Cronwatch;

/**
 * The environment, read in one place (the SDK reads NODE_ENV). PHP has no
 * single convention, so the first of CRONWATCH_ENV, APP_ENV (Laravel,
 * Symfony, Craft) and WP_ENVIRONMENT_TYPE (WordPress) whose value, trimmed,
 * is not empty is used, lowercased (a value of only spaces counts as
 * unset), from getenv(), $_ENV, or $_SERVER, since frameworks that read a
 * .env file put its values in one of those; failing those, what a framework
 * integration names with setFallback() (the WordPress plugin gives
 * wp_get_environment_type(), which also reads the constant of that name).
 * "development", "dev", "local", "test", and "testing" are development (the
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

    /**
     * The words Laravel's env() reads as something other than text (null,
     * true, false, empty, with or without parentheses, in any case). Laravel
     * hands the config null, a bool, or "" for them while the variable still
     * holds the word, so a secret holding one counts as not set rather than
     * as the password "null".
     */
    private const NOT_A_SECRET = ['null', '(null)', 'true', '(true)', 'false', '(false)', 'empty', '(empty)'];

    /**
     * A secret from the environment (CRONWATCH_TOKEN, CRON_SECRET), from the
     * first of getenv(), $_ENV, and $_SERVER that holds one, or null. A value
     * that is empty or only whitespace (as JavaScript's trim() sees it), or
     * one of the words Laravel's env() reads as null, true, false, or empty,
     * counts as unset, so the dashboard and handlers fail closed. Any other
     * value is used as it is, untrimmed.
     */
    public static function secret(string $name): ?string
    {
        $value = getenv($name);
        if (is_string($value) && self::secretText($value) !== null) {
            return $value;
        }
        foreach ([$_ENV, $_SERVER] as $source) {
            if (isset($source[$name]) && is_string($source[$name]) && self::secretText($source[$name]) !== null) {
                return $source[$name];
            }
        }
        return null;
    }

    /**
     * A secret's text as given, or null when it counts as unset: empty, only
     * whitespace, or one of the words Laravel's env() reads as null, true,
     * false, or empty (see secret()). For a framework integration reading its
     * own config before it falls back to the environment.
     */
    public static function secretText(?string $value): ?string
    {
        if ($value === null || self::blank($value) || in_array(strtolower($value), self::NOT_A_SECRET, true)) {
            return null;
        }
        return $value;
    }

    /**
     * A token or secret given in code: a string, null (the opt-out), false
     * (the deprecated opt-out, until 2.0) or FromEnv::Read. A string that is
     * empty or only whitespace comes back as "", which each option reads as
     * not given. Anything else (true, a number, an array, an object) throws
     * a TypeError naming the option, so it never becomes a password, as a
     * caller without strict_types would otherwise make 5 the password "5".
     */
    public static function secretOption(mixed $value, string $what): string|FromEnv|false|null
    {
        if ($value === null || $value === false || $value === FromEnv::Read) {
            return $value;
        }
        if (!is_string($value)) {
            $type = match (true) {
                is_bool($value) => 'boolean',
                is_int($value), is_float($value) => 'number',
                is_array($value) => 'an array',
                default => 'object',
            };
            throw new \TypeError("{$what} must be a string, or null to opt out, not {$type}");
        }
        return self::blank($value) ? '' : $value;
    }

    /** Whether text is empty or only whitespace, as JavaScript's trim() sees it. */
    public static function blank(string $value): bool
    {
        return Js::trim($value) === '';
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
