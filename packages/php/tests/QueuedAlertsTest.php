<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Alert;
use Cronwatch\Alerts\Webhook;
use Cronwatch\Cronwatch;
use Cronwatch\Evaluate;
use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Js;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Tests\Support\Capture;
use Cronwatch\Tests\Support\Clock;
use PHPUnit\Framework\TestCase;

/**
 * Alerts held in a job's state (undelivered, and each entry of sending) are
 * plain JSON in the SDK, carried through every state write as they were
 * stored. A field a newer release adds to an alert, a key a newer release
 * adds to a sending entry, an empty object inside an alert's details, and a
 * sending entry that is not what this release writes all come back as
 * they were read.
 */
final class QueuedAlertsTest extends TestCase
{
    private const T0 = Clock::T0;

    private const ALERT = '{"type":"failed","run":null,"details":{"futureDetail":7,"nested":{},"list":[{}]},"job":"x","definition":{"name":"x"},"title":"x failed","message":"x failed","at":1767605400000,"futureAlertField":{"a":1}}';

    private static function state(string $sending): string
    {
        return '{"job":"x","open":{"failed":1767605400000},"consecutiveFailures":1,"silencedUntil":null,"lastAlertAt":null,"pendingRecovery":[],"undelivered":[' . self::ALERT . '],"version":3,"sending":' . $sending . '}';
    }

    private static function roundTrip(string $json): string
    {
        return Js::stringify(JobState::fromJson(Js::parse($json))->toJson());
    }

    public function testAnUndeliveredAlertKeepsFieldsItDoesNotKnowAndEmptyObjectsInItsDetails(): void
    {
        $json = self::state('[{"until":1767605700000,"alert":' . self::ALERT . '}]');
        $this->assertSame($json, self::roundTrip($json));
        $normalized = Evaluate::normalizeState(JobState::fromJson(Js::parse($json)), 'x');
        $this->assertSame($json, Js::stringify($normalized->toJson()));
    }

    public function testSendingEntriesAreKeptAsStoredMalformedOnesIncluded(): void
    {
        $sending = '["x",null,{"until":"x"},{"until":5,"alert":[1]},{"until":1767605700000,"alert":{"type":"failed","at":1},"futureEntryKey":true},{"futureEntryKey":1,"until":1767605700000,"alert":' . self::ALERT . '}]';
        $json = self::state($sending);
        $this->assertSame($json, self::roundTrip($json));

        // Holding a new alert adds an entry and leaves the stored ones alone.
        $state = JobState::fromJson(Js::parse($json));
        $held = Evaluate::holdAlerts($state, [Alert::fromJson(Js::parse(str_replace('1767605400000,"futureAlertField"', '1767605460000,"futureAlertField"', self::ALERT)))], self::T0 + 300_000, false)['state'];
        $written = Js::parse(Js::stringify($held->toJson()));
        $this->assertCount(7, $written->sending);
        $this->assertSame(substr($sending, 1, -1), substr(Js::stringify(array_slice($written->sending, 0, 6)), 1, -1));
    }

    public function testAReleasedEntryKeepsItsAlertsUnknownFields(): void
    {
        $json = self::state('[{"until":5,"futureEntryKey":1,"alert":' . str_replace('1767605400000,"futureAlertField"', '1767605460000,"futureAlertField"', self::ALERT) . '}]');
        $released = Evaluate::releaseSending(JobState::fromJson(Js::parse($json)), self::T0)['state'];
        $written = Js::stringify($released->toJson());
        $this->assertStringNotContainsString('"sending"', $written);
        $this->assertSame(2, substr_count($written, '"futureAlertField":{"a":1}'));
        $this->assertSame(2, substr_count($written, '"nested":{}'));
    }

    public function testARetriedAlertIsSentWithItsUnknownFieldsAndASilenceKeepsThem(): void
    {
        $clock = new Clock(self::T0 + 60_000);
        $store = new MemoryStore();
        $store->upsertJob(JobDefinition::fromJson(['name' => 'x']), self::T0);
        $state = JobState::fromJson(Js::parse(self::state('[]')));
        $store->setState($state);

        $cw = new Cronwatch(store: $store, now: $clock, alerts: [], cronSecret: null);
        $cw->silence('x', '1m');
        $this->assertStringContainsString('"futureAlertField":{"a":1}', Js::stringify($store->getState('x')->toJson()));
        $this->assertStringContainsString('"nested":{},"list":[{}]', Js::stringify($store->getState('x')->toJson()));

        $capture = new Capture();
        $cw = new Cronwatch(store: $store, now: $clock, alerts: [$capture], cronSecret: null);
        $clock->advance(120_000);
        $cw->check();
        $this->assertSame(['failed'], $capture->types());
        $body = Js::stringify(['schema' => Webhook::SCHEMA, ...$capture->alerts[0]->toJson()]);
        $this->assertStringContainsString('"futureAlertField":{"a":1}', $body);
        $this->assertStringContainsString('"details":{"futureDetail":7,"nested":{},"list":[{}]}', $body);
    }
}
