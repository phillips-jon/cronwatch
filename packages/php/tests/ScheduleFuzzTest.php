<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Js;
use Cronwatch\Schedule;
use Cronwatch\Tests\Support\Node;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * The croner port against croner itself: thousands of generated cron
 * expressions (valid and not, in zones with and without daylight saving,
 * from times around the clock changes) answered by the SDK in Node
 * (tests/node/schedule_fuzz.mjs) and by this package, which must agree on
 * every error message and every fire time. Seeded, so a failure repeats.
 */
final class ScheduleFuzzTest extends TestCase
{
    private const ZONES = [null, 'UTC', 'America/New_York', 'Europe/London', 'Australia/Lord_Howe', 'America/Santiago', 'Asia/Kolkata', 'Pacific/Chatham', 'Europe/Berlin'];
    private const MONTHS = ['jan', 'FEB', 'Mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
    private const DAYS = ['sun', 'MON', 'Tue', 'wed', 'thu', 'fri', 'sat'];
    private const NICKNAMES = ['@yearly', '@annually', '@monthly', '@weekly', '@daily', '@midnight', '@hourly', '@HOURLY', '@reboot', '@every'];

    private static function chance(): float
    {
        return mt_rand() / mt_getrandmax();
    }

    private static function pick(array $items): mixed
    {
        return $items[mt_rand(0, count($items) - 1)];
    }

    /** One cron field: mostly valid, sometimes out of range or malformed. */
    private static function field(int $low, int $high, ?array $names = null): string
    {
        $size = $high - $low + 1;
        $value = function () use ($low, $high, $names): string {
            if ($names !== null && self::chance() < 0.3) {
                return self::pick($names);
            }
            if (self::chance() < 0.05) {
                return (string) self::pick([$high + 1, $low - 1, 99]);
            }
            return (string) mt_rand($low, $high);
        };
        $kind = self::chance();
        if ($kind < 0.3) {
            return '*';
        }
        if ($kind < 0.45) {
            return $value();
        }
        if ($kind < 0.6) {
            $pair = [mt_rand($low, $high), mt_rand($low, $high)];
            sort($pair);
            [$a, $b] = $pair;
            if (self::chance() < 0.05) {
                [$a, $b] = [$b + 1, $a];
            }
            return "{$a}-{$b}";
        }
        if ($kind < 0.75) {
            return '*/' . self::pick([1, 2, 3, 5, 7, 10, 15, 30, $size, $size + 1, 0]);
        }
        if ($kind < 0.85) {
            $pair = [mt_rand($low, $high), mt_rand($low, $high)];
            sort($pair);
            return "{$pair[0]}-{$pair[1]}/" . mt_rand(1, max(1, intdiv($size, 2)));
        }
        if ($kind < 0.97) {
            return implode(',', array_map(fn () => $value(), range(1, mt_rand(2, 4))));
        }
        return self::pick(['?', 'x', '', '5/15', '/5', '1-', '-1']);
    }

    private static function dayOfMonth(): string
    {
        $kind = self::chance();
        if ($kind < 0.1) {
            return self::pick(['L', 'LW', '15W', '1W', '31W', '5L', 'L,15']);
        }
        if ($kind < 0.2) {
            return '?';
        }
        return self::field(1, 31);
    }

    private static function dayOfWeek(): string
    {
        $kind = self::chance();
        if ($kind < 0.1) {
            return mt_rand(0, 7) . '#' . mt_rand(0, 6);
        }
        if ($kind < 0.18) {
            return mt_rand(0, 6) . 'L';
        }
        if ($kind < 0.24) {
            return '+' . self::field(0, 7, self::DAYS);
        }
        if ($kind < 0.3) {
            return self::pick(self::DAYS) . '-' . self::pick(self::DAYS);
        }
        return self::field(0, 7, self::DAYS);
    }

    private static function expression(): string
    {
        if (self::chance() < 0.05) {
            return self::pick(self::NICKNAMES);
        }
        $parts = [self::field(0, 59), self::field(0, 23), self::dayOfMonth(), self::field(1, 12, self::MONTHS), self::dayOfWeek()];
        if (self::chance() < 0.25) {
            array_unshift($parts, self::field(0, 59));
        }
        if (self::chance() < 0.02) {
            $parts[] = '*';
        }
        return implode(' ', $parts);
    }

    /** @return list<array{schedule: string, timezone: ?string, from: int, count: int}> */
    private static function cases(int $seed, int $count): array
    {
        // Around the nights clocks change in the zones above, and ordinary days.
        $starts = [
            Js::dateUtc(2026, 2, 8, 6, 30), Js::dateUtc(2026, 10, 1, 5, 10), Js::dateUtc(2026, 2, 29, 0, 45),
            Js::dateUtc(2026, 9, 25, 0, 50), Js::dateUtc(2026, 9, 3, 15, 20), Js::dateUtc(2026, 3, 4, 14, 55),
            Js::dateUtc(2026, 0, 5, 9, 30), Js::dateUtc(2027, 1, 27, 23, 59, 59), Js::dateUtc(2028, 1, 28, 12),
        ];
        mt_srand($seed);
        $out = [];
        for ($i = 0; $i < $count; $i++) {
            $from = self::pick($starts) + mt_rand(-3, 3) * 3_600_000 + mt_rand(0, 3_599) * 1000 + self::pick([0, 0, 500, 999]);
            $out[] = ['schedule' => self::expression(), 'timezone' => self::pick(self::ZONES), 'from' => $from, 'count' => mt_rand(1, 6)];
        }
        return $out;
    }

    /** @param array{schedule: string, timezone: ?string, from: int, count: int} $case */
    private static function phpAnswer(array $case): array
    {
        try {
            $parsed = Schedule::parse($case['schedule'], $case['timezone']);
        } catch (\InvalidArgumentException $error) {
            return ['error' => $error->getMessage()];
        }
        $fires = [];
        $t = $case['from'];
        for ($i = 0; $i < $case['count']; $i++) {
            $t = Schedule::nextFire($parsed, $t, null);
            $fires[] = $t;
            if ($t === null) {
                break;
            }
        }
        return ['fires' => $fires];
    }

    public static function seeds(): iterable
    {
        foreach ([1, 2, 3] as $seed) {
            yield "seed {$seed}" => [$seed];
        }
    }

    #[DataProvider('seeds')]
    public function testThePortAgreesWithCroner(int $seed): void
    {
        $why = Node::unavailable();
        if ($why !== null) {
            $this->markTestSkipped("croner parity: {$why}");
        }
        $generated = self::cases($seed, 1000);
        $file = tempnam(sys_get_temp_dir(), 'cronwatch-fuzz-');
        try {
            file_put_contents($file, json_encode($generated, JSON_THROW_ON_ERROR));
            $expected = json_decode(Node::run('schedule_fuzz.mjs', $file), true, 512, JSON_THROW_ON_ERROR);
        } finally {
            unlink($file);
        }
        $differences = [];
        $parsed = 0;
        foreach ($generated as $i => $case) {
            $want = $expected[$i];
            $got = self::phpAnswer($case);
            $parsed += isset($want['fires']) ? 1 : 0;
            if (isset($want['throws'])) {
                // croner walks by recursion, a year at a time, so a date no month
                // has (February 30) runs out of stack before the year 3000. The
                // port walks in a loop and finds nothing: the schedule never fires.
                $n = count($want['fires']);
                if (array_slice($got['fires'] ?? [], 0, $n + 1) !== [...$want['fires'], null]) {
                    $differences[] = json_encode($case) . "\n    croner threw {$want['throws']} after " . json_encode($want['fires']) . "\n    php " . json_encode($got);
                }
                continue;
            }
            if ($got !== $want) {
                $show = fn (array $answer) => json_encode(isset($answer['fires']) ? array_map(fn ($t) => $t === null ? null : Js::iso($t), $answer['fires']) : $answer);
                $differences[] = json_encode($case) . "\n    croner {$show($want)}\n    php    {$show($got)}";
            }
        }
        $this->assertSame([], $differences, count($differences) . ' of ' . count($generated) . " differ:\n" . implode("\n", array_slice($differences, 0, 10)));
        $this->assertGreaterThan(300, $parsed, 'enough of the generated expressions are valid to exercise the walk');
    }
}
