<?php

declare(strict_types=1);

namespace Cronwatch\Laravel;

/**
 * What ->cronwatch() set on a scheduled event, kept beside the event rather
 * than on it (the event has no property for it, and PHP 8.2 deprecates
 * adding one), and gone with the event.
 *
 * @internal
 */
final class EventOptions
{
    /** @var \WeakMap<object, array<string, mixed>|false>|null */
    private static ?\WeakMap $options = null;

    /** @param array<string, mixed>|false $options */
    public static function set(object $event, array|false $options): void
    {
        self::$options ??= new \WeakMap();
        self::$options[$event] = $options;
    }

    /** @return array<string, mixed>|false|null the options given, false for an event left out, null when none were given */
    public static function get(object $event): array|false|null
    {
        return self::$options !== null && isset(self::$options[$event]) ? self::$options[$event] : null;
    }
}
