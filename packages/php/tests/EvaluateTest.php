<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Evaluate;
use Cronwatch\Evaluation;
use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Run;
use Cronwatch\Tests\Support\Clock;
use PHPUnit\Framework\TestCase;

/** The cases of evaluate.test.ts that conformance/ does not already pin. */
final class EvaluateTest extends TestCase
{
    private const T0 = Clock::T0;
    private const HOUR = Clock::HOUR;

    private static function okRun(int $startedAt, array $metrics): Run
    {
        static $n = 0;
        $n++;
        return new Run("r{$n}", 'j', 'ok', $startedAt, $startedAt + 1000, 1000, metrics: $metrics);
    }

    /** @return list<string> */
    private static function types(Evaluation $e): array
    {
        return array_map(fn ($a) => $a->type, $e->alerts);
    }

    public function testFloorsAFloorOrZeroAfterFiveRunsThatAllReportedMore(): void
    {
        $floored = new JobDefinition(['name' => 'j', 'floor' => ['rows' => 10]]);
        $short = Evaluate::onRunFinish($floored, self::okRun(self::T0, ['rows' => 9]), Evaluate::emptyState('j'), [], self::T0 + 1000);
        $this->assertSame(['under_floor'], self::types($short));
        $this->assertSame([['metric' => 'rows', 'value' => 9, 'limit' => 10, 'basis' => 'floor']], $short->alerts[0]->details['breaches']);
        $back = Evaluate::onRunFinish($floored, self::okRun(self::T0 + self::HOUR, ['rows' => 10]), $short->state, [], self::T0 + self::HOUR + 1000);
        $this->assertSame(['recovered'], self::types($back));
        $this->assertNull($back->state->underFloor);

        $bare = new JobDefinition(['name' => 'j']);
        $history = array_map(fn (int $i) => self::okRun(self::T0 - $i * self::HOUR, ['rows' => 100 * $i, 'errors' => 0]), [1, 2, 3, 4, 5]);
        $this->assertSame([], Evaluate::onRunFinish($bare, self::okRun(self::T0, ['rows' => 0]), Evaluate::emptyState('j'), array_slice($history, 1), self::T0)->alerts, 'four runs are not a baseline');
        $this->assertSame([], Evaluate::onRunFinish($bare, self::okRun(self::T0, ['rows' => 1, 'errors' => 0]), Evaluate::emptyState('j'), $history, self::T0)->alerts, 'an always-0 metric never alerts');
        $zero = Evaluate::onRunFinish($bare, self::okRun(self::T0, ['rows' => 0, 'errors' => 0]), Evaluate::emptyState('j'), $history, self::T0);
        $this->assertSame([['metric' => 'rows', 'value' => 0, 'limit' => 100, 'basis' => 'the last 5 runs all reported more than 0, the lowest 100']], $zero->alerts[0]->details['breaches']);
        $this->assertSame(['rows'], $zero->state->underFloor);
        $this->assertSame(['rows'], JobState::fromJson($zero->state->toJson())->underFloor);

        // A job that keeps writing nothing stays open, past the point where its zeros are all the history there is.
        $state = $zero->state;
        $runs = $history;
        for ($i = 1; $i <= 30; $i++) {
            array_unshift($runs, self::okRun(self::T0 + ($i - 1) * self::HOUR, ['rows' => 0, 'errors' => 0]));
            $next = Evaluate::onRunFinish($bare, self::okRun(self::T0 + $i * self::HOUR, ['rows' => 0, 'errors' => 0]), $state, array_slice($runs, 0, 25), self::T0 + $i * self::HOUR);
            $this->assertSame([], $next->alerts);
            $this->assertSame(self::T0, $next->state->open['under_floor']);
            $state = $next->state;
        }
        $recovered = Evaluate::onRunFinish($bare, self::okRun(self::T0 + 31 * self::HOUR, ['rows' => 5, 'errors' => 0]), $state, array_slice($runs, 0, 25), self::T0 + 31 * self::HOUR);
        $this->assertSame(['recovered'], self::types($recovered));
        $this->assertSame(['under_floor'], $recovered->alerts[0]->details['after']);

        // A metric that has reported 0 before is judged as usual for it, and a floor of 0 turns the check off.
        $mixed = [...array_slice($history, 0, 4), self::okRun(self::T0 - 6 * self::HOUR, ['rows' => 0])];
        $this->assertSame([], Evaluate::onRunFinish($bare, self::okRun(self::T0, ['rows' => 0]), Evaluate::emptyState('j'), $mixed, self::T0)->alerts);
        $this->assertSame([], Evaluate::onRunFinish(new JobDefinition(['name' => 'j', 'floor' => ['rows' => 0]]), self::okRun(self::T0, ['rows' => 0]), Evaluate::emptyState('j'), $history, self::T0)->alerts);
    }
}
