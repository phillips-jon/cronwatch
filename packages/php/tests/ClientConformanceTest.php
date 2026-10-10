<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Alert;
use Cronwatch\Cronwatch;
use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Js;
use Cronwatch\Run;
use Cronwatch\Tests\Support\Backend;
use Cronwatch\Tests\Support\Capture;
use Cronwatch\Tests\Support\Clock;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * Replays conformance/client.json, the cases driven through the client's
 * public API: the run ids start(), resume(), and recordRun() take, and stored
 * data a newer release wrote (an unknown state field, condition, definition
 * key, run status, and trigger) kept through a check, a silence, an
 * unsilence, a summary, and a run, over the memory store and SQLite (and the
 * servers, when they are set).
 */
final class ClientConformanceTest extends TestCase
{
    private const FILE = __DIR__ . '/../../../conformance/client.json';

    private static ?\stdClass $fixture = null;

    private static function fixture(): \stdClass
    {
        return self::$fixture ??= Js::parse((string) file_get_contents(self::FILE));
    }

    public function testRunIds(): void
    {
        $failures = [];
        foreach (self::fixture()->runIds as $i => $c) {
            $cw = new Cronwatch(alerts: [new Capture()], cronSecret: null, onError: fn () => null, now: new Clock());
            $job = $cw->job('j');
            try {
                match ($c->method) {
                    'start' => $job->start(id: $c->id)->finish(),
                    'resume' => $job->resume($c->id),
                    'recordRun' => $cw->recordRun(new Run(
                        id: $c->id,
                        job: 'j',
                        status: 'ok',
                        startedAt: Clock::T0 - 1000,
                        finishedAt: Clock::T0,
                        durationMs: 1000,
                        trigger: 'run',
                    )),
                };
                $got = null;
            } catch (\InvalidArgumentException $error) {
                $got = $error->getMessage();
            }
            $want = $c->error ?? null;
            if ($got !== $want) {
                $failures[] = "#{$i} {$c->method} of " . Js::length16($c->id) . ' characters: expected ' . ($want ?? 'ok') . ', got ' . ($got ?? 'ok');
            }
        }
        $this->assertSame([], $failures, implode("\n", $failures));
    }

    /** @return iterable<string, array{string}> */
    public static function backends(): iterable
    {
        foreach (['memory', 'sqlite', 'mysql', 'mariadb', 'postgres'] as $kind) {
            yield $kind => [$kind];
        }
    }

    #[DataProvider('backends')]
    public function testUnknownFieldsAreKept(string $kind): void
    {
        $why = Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        $backend = Backend::make($kind);
        try {
            $this->replayUnknownFields($backend->open());
        } finally {
            $backend->done();
        }
    }

    private function replayUnknownFields(\Cronwatch\Store\Store $store): void
    {
        $f = self::fixture()->unknownFields;
        $store->init();
        $store->upsertJob(JobDefinition::fromJson($f->seed->definition), $f->seed->createdAt);
        $store->setState(JobState::fromJson($f->seed->state));
        foreach ($f->seed->runs as $run) {
            $store->insertRun(Run::fromJson($run));
        }

        $clock = new Clock();
        $capture = new Capture();
        $errors = [];
        $cw = new Cronwatch(
            store: $store,
            alerts: [$capture],
            cronSecret: null,
            onError: function (\Throwable $error, string $where) use (&$errors): void {
                $errors[] = "{$where}: {$error->getMessage()}";
            },
            now: $clock,
        );

        foreach ($f->steps as $i => $step) {
            $capture->alerts = [];
            $errors = [];
            $label = "step {$i} ({$step->op})";
            switch ($step->op) {
                case 'check':
                    $clock->set($step->at);
                    $cw->check();
                    break;
                case 'silence':
                    $clock->set($step->at);
                    $cw->silence('keep', $step->for);
                    break;
                case 'unsilence':
                    $clock->set($step->at);
                    $cw->unsilence('keep');
                    break;
                case 'summary':
                    $clock->set($step->at);
                    $this->assertSame(self::canonical($step->summary, true), self::canonical($cw->jobSummary('keep'), true), "{$label}: the summary");
                    break;
                case 'declareAndRun':
                    $job = $cw->job('keep', Js::plain($step->declared));
                    $clock->set($step->startedAt);
                    $handle = $job->start(id: $step->id);
                    $clock->set($step->finishedAt);
                    $handle->finish($step->output);
                    break;
                default:
                    $this->fail("{$label}: an op this replay does not know");
            }
            $expect = $step->expect;
            $this->assertSame(self::canonical($expect->job), self::canonical($store->getJob('keep')), "{$label}: the stored job");
            $this->assertSame(self::canonical($expect->state), self::canonical($store->getState('keep')), "{$label}: the stored state");
            $this->assertSame(self::canonical($expect->runs), self::canonical($store->listRuns('keep', 10)), "{$label}: the stored runs");
            $this->assertSame(self::canonical($expect->alerts), self::canonical(array_map(fn (Alert $a) => $a->toJson(), $capture->alerts)), "{$label}: the alerts sent");
            $this->assertSame($expect->errors, $errors, "{$label}: the errors reported");
        }
    }

    /**
     * A value as JSON, with every object's keys sorted, so two values compare
     * as JSON values whatever order the keys were written in. With
     * `openAsSet`, a summary's `open` is sorted too: Postgres's JSONB does not
     * keep key order, so the order there follows the store.
     */
    private static function canonical(mixed $value, bool $openAsSet = false): string
    {
        $decoded = json_decode(Js::stringify($value), true, 512, JSON_THROW_ON_ERROR);
        if ($openAsSet && is_array($decoded) && is_array($decoded['open'] ?? null)) {
            sort($decoded['open']);
        }
        $sort = function (mixed $v) use (&$sort): mixed {
            if (!is_array($v)) {
                return $v;
            }
            if (!array_is_list($v)) {
                ksort($v, SORT_STRING);
            }
            return array_map($sort, $v);
        };
        return (string) json_encode($sort($decoded), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRESERVE_ZERO_FRACTION);
    }
}
