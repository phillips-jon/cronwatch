<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Duration;
use PHPUnit\Framework\TestCase;

/** The cap on a duration string's length, which the conformance cases also replay: the parts pattern is quadratic on a long run of digits. */
final class DurationTest extends TestCase
{
    private const TOO_LONG = 'is too long for a duration (more than 64 characters)';

    private static function error(mixed ...$args): string
    {
        try {
            Duration::parse(...$args);
        } catch (\InvalidArgumentException $e) {
            return $e->getMessage();
        }
        self::fail('no error');
    }

    public function testAStringOver64CharactersIsRefusedQuotingItsFirst32(): void
    {
        $this->assertSame(32 * 60_000, Duration::parse(str_repeat('1m', 32)));
        $long = ' ' . str_repeat('1m', 32);
        $this->assertSame('grace "' . substr($long, 0, 32) . '..." ' . self::TOO_LONG, self::error($long, 'grace'));
        // Characters are code points: forty emoji are eighty UTF-16 units (160 bytes) but under the cap.
        $this->assertStringStartsWith('duration "' . str_repeat("\u{1F600}", 40) . '" is not a duration like', self::error(str_repeat("\u{1F600}", 40)));
        $this->assertSame('duration "' . str_repeat("\u{1F600}", 32) . '..." ' . self::TOO_LONG, self::error(str_repeat("\u{1F600}", 65)));
        // A byte that starts no character counts as one.
        $this->assertSame('duration "' . str_repeat("\xFF", 32) . '..." ' . self::TOO_LONG, self::error(str_repeat("\xFF", 65)));
        $this->assertStringContainsString('is not a duration like', self::error(str_repeat("\xC3\xA9", 64)));
    }

    public function testAMegabyteOfDigitsIsRefusedAtOnce(): void
    {
        $started = hrtime(true);
        $this->assertSame('silence duration "' . str_repeat('1', 32) . '..." ' . self::TOO_LONG, self::error(str_repeat('1', 1 << 20), 'silence duration'));
        $this->assertLessThan(1e9, hrtime(true) - $started);
    }
}
