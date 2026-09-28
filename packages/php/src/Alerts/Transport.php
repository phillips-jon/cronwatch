<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

/**
 * The Http every channel and Claude triage uses when given no `http:`: one
 * set with set(), else a shared NativeHttp (curl, or PHP's streams). The
 * WordPress plugin sets one on wp_remote_post, so a channel a site adds
 * through its filters goes through WordPress's HTTP API too, and the
 * plugin's zip can leave NativeHttp out.
 */
final class Transport
{
    private static ?Http $default = null;

    public static function default(): Http
    {
        return self::$default ??= new NativeHttp();
    }

    /** Sets the Http channels and triage given no `http:` use; null goes back to NativeHttp. */
    public static function set(?Http $http): void
    {
        self::$default = $http;
    }
}
