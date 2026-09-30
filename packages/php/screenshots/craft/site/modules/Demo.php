<?php

namespace modules;

use Cronwatch\Cronwatch;

/**
 * What the seed (app/seed) tells the site's commands and jobs about the run
 * it is making: how many things it handled, and whether what it talks to is
 * down. Outside the seed every run goes well.
 */
final class Demo
{
    /** @var array<string, mixed> */
    public static array $scenario = [];

    public static function get(string $key, mixed $default = null): mixed
    {
        return self::$scenario[$key] ?? $default;
    }

    public static function log(mixed ...$parts): void
    {
        Cronwatch::current()?->log(...$parts);
    }

    public static function metric(string $name, int|float $value): void
    {
        Cronwatch::current()?->metric($name, $value);
    }
}
