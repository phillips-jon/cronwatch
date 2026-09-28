<?php

declare(strict_types=1);

namespace Cronwatch\Cron;

use Cronwatch\Js;

/**
 * IANA zones through PHP's own zone database, or PHP's default zone
 * (date_default_timezone_get()) when none is named, as JavaScript's Date
 * uses the process's; and croner's wall-clock arithmetic on them.
 *
 * @internal
 */
final class Zone
{
    /** @var array<string, string>|null Lowercased names to the database's spelling. */
    private static ?array $names = null;

    /** @var array<string, \DateTimeZone> */
    private static array $zones = [];

    /** The zone's name as the database spells it, matched without regard to case as Intl does, or null for a name that is not an IANA zone. */
    public static function canonical(string $name): ?string
    {
        if (self::$names === null) {
            self::$names = ['utc' => 'UTC'];
            foreach (\DateTimeZone::listIdentifiers(\DateTimeZone::ALL_WITH_BC) as $id) {
                self::$names[strtolower($id)] = $id;
            }
        }
        return self::$names[strtolower($name)] ?? null;
    }

    public static function isValid(mixed $name): bool
    {
        return is_string($name) && $name !== '' && self::canonical($name) !== null;
    }

    /** A zone by its IANA name, or PHP's default zone for null. */
    public static function get(?string $name): \DateTimeZone
    {
        $key = $name ?? '';
        if (!isset(self::$zones[$key])) {
            if ($name === null) {
                return new \DateTimeZone(date_default_timezone_get());
            }
            $canonical = self::canonical($name);
            if ($canonical === null) {
                throw new \InvalidArgumentException("timezone \"{$name}\" is not an IANA timezone");
            }
            self::$zones[$key] = new \DateTimeZone($canonical);
        }
        return self::$zones[$key];
    }

    /** Seconds the wall clock is ahead of UTC at epoch second `sec`. */
    public static function offset(int $sec, ?string $tz): int
    {
        return self::get($tz)->getOffset(new \DateTimeImmutable('@' . $sec));
    }

    /**
     * The wall clock at epoch second `sec`: year, month (1 to 12), day, hour, minute, second.
     *
     * @return array{int, int, int, int, int, int}
     */
    public static function wall(int $sec, ?string $tz): array
    {
        $local = $sec + self::offset($sec, $tz);
        $days = Js::div($local, 86_400);
        $rest = $local - $days * 86_400;
        [$year, $month, $day] = Js::civilFromDays($days);
        return [$year, $month, $day, intdiv($rest, 3600), intdiv($rest % 3600, 60), $rest % 60];
    }

    /**
     * A wall-clock time read as if it were UTC, in epoch seconds (croner's T()).
     *
     * @param array{int, int, int, int, int, int} $w
     */
    public static function civilSeconds(array $w): int
    {
        [$year, $month, $day, $hour, $minute, $second] = $w;
        return Js::div(Js::dateUtc($year, $month - 1, $day, $hour, $minute, $second), 1000);
    }

    /**
     * Croner's fromTZ: the instant a wall-clock time names, in epoch seconds.
     * A time that falls in a spring-forward gap is moved forward by the gap;
     * a time that occurs twice (fall back) is the earlier of the two.
     *
     * @param array{int, int, int, int, int, int} $w
     */
    public static function toUtc(array $w, ?string $tz): int
    {
        $target = self::civilSeconds($w);
        $guess = $target + ($target - self::civilSeconds(self::wall($target, $tz)));
        $seen = self::wall($guess, $tz);
        if ($seen === $w) {
            $earlier = $guess - 3600;
            return self::wall($earlier, $tz) === $w ? $earlier : $guess;
        }
        $shifted = $guess + $target - self::civilSeconds($seen);
        if (self::wall($shifted, $tz) === $w) {
            return $shifted;
        }
        return max($guess, $shifted);
    }
}
