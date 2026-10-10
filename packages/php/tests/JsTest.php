<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Js;
use PHPUnit\Framework\TestCase;

/** The places JavaScript and PHP disagree about text and numbers, settled the JavaScript way. */
final class JsTest extends TestCase
{
    public function testNumbersAreWrittenAsStringNumberWritesThem(): void
    {
        $cases = [
            [0.1, '0.1'], [1e-7, '1e-7'], [1e-6, '0.000001'], [1e21, '1e+21'], [1e20, '100000000000000000000'],
            [2.0, '2'], [-0.5, '-0.5'], [0.30000000000000004, '0.30000000000000004'], [2 / 3, '0.6666666666666666'],
            [5e-324, '5e-324'], [1.7976931348623157e308, '1.7976931348623157e+308'], [-0.0, '0'], [123456789, '123456789'],
            [9007199254740993, '9007199254740992'], [NAN, 'NaN'], [INF, 'Infinity'], [-INF, '-Infinity'],
        ];
        foreach ($cases as [$value, $text]) {
            $this->assertSame($text, Js::number($value), var_export($value, true));
        }
        $this->assertSame('null', Js::stringify(NAN), 'JSON has no NaN');
    }

    public function testStringifyIsJsonStringify(): void
    {
        $this->assertSame('{"2":"b","10":"c","a":1,"0x":2}', Js::stringify(['a' => 1, '10' => 'c', '2' => 'b', '0x' => 2]), 'array-index keys first, ascending');
        $this->assertSame('{}', Js::stringify(Js::obj([])));
        $this->assertSame('[]', Js::stringify([]));
        $this->assertSame('"a\u0001\n\"\\\\/é😀' . "\u{2028}\"", Js::stringify("a\x01\n\"\\/é😀\u{2028}"), 'only control characters, quotes, and backslashes escaped');
    }

    public function testLengthsAndCutsAreInUtf16CodeUnits(): void
    {
        $this->assertSame(5, Js::length16('héllo'));
        $this->assertSame(4, Js::length16('a😀b'));
        $this->assertSame("a\u{FFFD}", Js::head16('a😀b', 2), 'a pair cut in half leaves U+FFFD');
        $this->assertSame('a😀', Js::head16('a😀b', 3));
        $this->assertSame("\u{FFFD}b", Js::tail16('a😀b', 2));
        $this->assertSame('😀b', Js::tail16('a😀b', 3));
        $this->assertSame('a😀b', Js::tail16('a😀b', 9));
    }

    public function testBytesThatAreNotUtf8BecomeReplacementCharacters(): void
    {
        $this->assertSame("ok\u{FFFD}ok", Js::wellFormed("ok\xFFok"));
        $this->assertSame("\u{FFFD}\u{FFFD}", Js::wellFormed("\xE2\x82\xC0"), 'one U+FFFD per maximal subpart');
        $this->assertSame("\u{FFFD}a", Js::wellFormed("\xF0\x9Fa"));
        $this->assertSame('😀', Js::wellFormed('😀'));
    }

    public function testTrimIsJavaScriptsTrim(): void
    {
        $this->assertSame('x', Js::trim("\u{FEFF}\u{A0} x\u{3000}\n"));
        $this->assertSame("\u{85}x", Js::trim("\u{85}x"), 'U+0085 is not whitespace to JavaScript');
    }

    public function testIsoAndDateUtc(): void
    {
        $this->assertSame('2026-01-05T09:30:00.000Z', Js::iso(1767605400000));
        $this->assertSame('1969-12-31T23:59:59.999Z', Js::iso(-1));
        $this->assertSame(Js::dateUtc(2026, 1, 1), Js::dateUtc(2025, 13, 1), 'months overflow into years');
        $this->assertSame(Js::dateUtc(2026, 2, 0), Js::dateUtc(2026, 1, 28), 'day 0 is the last day of the month before');
    }

    public function testRoundIsMathRound(): void
    {
        $this->assertSame(3, Js::round(2.5));
        $this->assertSame(-2, Js::round(-2.5));
        $this->assertSame(0, Js::round(0.49999999999999994));
    }
}
