<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Alert;
use Cronwatch\Alerts\Custom;
use Cronwatch\Cronwatch;
use Cronwatch\Evaluate;
use Cronwatch\JobDefinition;
use Cronwatch\Js;
use Cronwatch\RunStatus;
use Cronwatch\Store\Store;
use Cronwatch\Tests\Support\Backend;
use Cronwatch\Web\Request;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * Rows another process wrote: a running run that started at the lowest
 * BIGINT, and a state whose version is 1.5. Neither may make a statement
 * fail, or refuse every write of the job for good (checkOverForeignRows in
 * the SDK's stores.test.ts).
 */
final class ForeignRowsTest extends TestCase
{
    public static function stores(): iterable
    {
        foreach (['sqlite', 'mysql', 'mariadb', 'postgres'] as $kind) {
            yield $kind => [$kind];
        }
    }

    private const STORE_FIXTURE = __DIR__ . '/../../../conformance/store.json';

    private static function foreignRows(): array
    {
        return json_decode((string) file_get_contents(self::STORE_FIXTURE), true, 512, JSON_THROW_ON_ERROR)['foreignRows'];
    }

    /** A value as plain JSON (objects as arrays), to compare whatever key order or object class it came in. */
    private static function plain(mixed $value): mixed
    {
        return json_decode(Js::stringify($value), true, 512, JSON_THROW_ON_ERROR);
    }

    /** One row as SQLite holds it: a string as TEXT, a number as INTEGER or REAL, null as NULL. */
    private static function insertRow(\PDO $pdo, string $table, array $row): void
    {
        $keys = array_keys($row);
        $statement = $pdo->prepare("INSERT INTO cronwatch_{$table} (" . implode(', ', $keys) . ') VALUES (' . implode(', ', array_fill(0, count($keys), '?')) . ')');
        foreach (array_values($row) as $i => $value) {
            $statement->bindValue($i + 1, $value, match (true) {
                $value === null => \PDO::PARAM_NULL,
                is_int($value) => \PDO::PARAM_INT,
                default => \PDO::PARAM_STR,
            });
        }
        $statement->execute();
    }

    /** Each foreign row of store.json reads leniently (stores.test.ts, "each foreign row reads leniently"). */
    public function testEachForeignRowReadsLeniently(): void
    {
        foreach (self::foreignRows()['rows'] as $c) {
            $backend = Backend::make('sqlite');
            try {
                $store = $backend->open();
                $store->init();
                self::insertRow($backend->pdo(), $c['table'], $c['row']);
                $label = "{$c['table']} " . json_encode($c['row']);
                if ($c['table'] === 'jobs') {
                    $job = $store->getJob($c['row']['name']);
                    $this->assertEquals($c['read'], self::plain($job->toJson()), $label);
                    $this->assertSame($c['readable'], $job->isReadable(), $label);
                    $this->assertEquals([$c['read']], self::plain(array_map(fn ($j) => $j->toJson(), $store->listJobs())), $label);
                } elseif ($c['table'] === 'runs') {
                    $this->assertEquals($c['read'], self::plain($store->getRun($c['row']['id'])), $label);
                    $this->assertEquals([$c['read']], self::plain($store->listRuns($c['row']['job'], 10)), $label);
                } else {
                    $this->assertEquals($c['read'], self::plain(Evaluate::normalizeState($store->getState($c['row']['job']), $c['row']['job'])), $label);
                }
            } finally {
                $backend->done();
            }
        }
    }

    /** A check, a silence and every page over the foreign rows of store.json (stores.test.ts). */
    public function testACheckASilenceAndEveryPageOverForeignRows(): void
    {
        $fixture = self::foreignRows();
        $c = $fixture['check'];
        $backend = Backend::make('sqlite');
        try {
            $store = $backend->open();
            $store->init();
            $pdo = $backend->pdo();
            $byTable = fn (string $table) => array_map(fn (array $r) => $r['row'], array_values(array_filter($fixture['rows'], fn (array $r) => $r['table'] === $table)));
            $jobs = [...$byTable('jobs'), ...$c['extraJobs']];
            foreach ($jobs as $row) {
                self::insertRow($pdo, 'jobs', $row);
            }
            foreach ([...$byTable('runs'), ...$c['extraRuns']] as $row) {
                self::insertRow($pdo, 'runs', $row);
            }
            foreach ($byTable('state') as $row) {
                self::insertRow($pdo, 'state', $row);
            }
            $names = array_column($jobs, 'name');
            $errors = [];
            $reported = function () use (&$errors, $names): array {
                $jobs = [];
                foreach ($errors as $where) {
                    $found = $where;
                    foreach ($names as $name) {
                        if (str_ends_with($where, " {$name}")) {
                            $found = $name;
                        }
                    }
                    $jobs[$found] = true;
                }
                $errors = [];
                $jobs = array_map('strval', array_keys($jobs));
                sort($jobs);
                return $jobs;
            };
            $sent = [];
            $cw = new Cronwatch(
                store: $store,
                alerts: [new Custom('capture', function (Alert $alert) use (&$sent): void {
                    $sent[] = ['type' => $alert->type, 'job' => $alert->job, 'at' => $alert->at];
                })],
                cronSecret: null,
                onError: function (\Throwable $e, string $where) use (&$errors): void {
                    $errors[] = $where;
                },
                now: fn () => $c['now'],
            );
            $result = $cw->check();
            $this->assertSame($c['reported'], $reported());
            $this->assertSame($c['alerts'], $sent);
            $health = [];
            foreach ($result->jobs as $job) {
                $health[$job->name] = $job->health;
            }
            $this->assertEquals($c['health'], $health);

            $cw->silence($c['silence']['job'], $c['silence']['for']);
            $this->assertSame($c['silence']['reported'], $reported());
            $this->assertEquals($c['silence']['state'], self::plain($store->getState($c['silence']['job'])));
            foreach ($c['states'] as $job => $state) {
                $raw = $pdo->query("SELECT state FROM cronwatch_state WHERE job = " . $pdo->quote($job))->fetchColumn();
                $this->assertEquals($state, json_decode((string) $raw, true), $job);
            }

            $web = $cw->routes(token: 'tok', basePath: '/cronwatch');
            foreach ($c['read']['pages'] as $page) {
                $response = $web->handle(Request::create('GET', "http://app.test{$page['path']}", ['authorization' => 'Bearer tok'], ''));
                $this->assertSame($page['status'], $response->status, $page['path']);
            }
            $this->assertSame($c['read']['reported'], $reported());
        } finally {
            $backend->done();
        }
    }

    /**
     * A queued alert whose run holds wrong-typed values ("startedAt": "x",
     * "error": 5, an object error, "id": {}) in `undelivered` and in
     * `sending` leaves the state readable: the job is checked, its failures
     * alert, and it can be silenced (review 2, medium 6).
     */
    #[DataProvider('stores')]
    public function testAQueuedAlertWhoseRunHoldsOddValuesLeavesTheStateReadable(string $kind): void
    {
        $why = Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        $backend = Backend::make($kind);
        try {
            $store = $backend->open();
            $store->init();
            $store->upsertJob(JobDefinition::fromJson(['name' => 'odd']), 1);
            $p = $backend->tables();
            $run = '{"id":{},"job":5,"status":[],"startedAt":"x","finishedAt":"y","durationMs":{},"error":{"message":"boom"},"output":5,"metrics":{"a":"x","b":2},"trigger":7}';
            $alert = '{"type":"failed","job":"odd","definition":{"name":"odd"},"run":' . $run . ',"title":"odd failed","message":"m","at":1,"details":{}}';
            $other = '{"type":"failed","job":"odd","definition":{"name":"odd"},"run":{"id":"r","job":"odd","status":"failed","startedAt":"x","error":5},"title":"t","message":"m","at":2,"details":{}}';
            $state = '{"job":"odd","open":{},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null,"pendingRecovery":[],"undelivered":[' . $alert . '],"sending":[{"until":1,"alert":' . $other . '}]}';
            $backend->pdo()->exec("INSERT INTO {$p}state (job, state) VALUES ('odd', '{$state}')");
            $sent = [];
            $errors = [];
            $cw = new Cronwatch(store: $store, alerts: [new Custom('capture', function (Alert $alert) use (&$sent): void {
                $sent[] = $alert->type;
            })], cronSecret: null, onError: function (\Throwable $e, string $where) use (&$errors): void {
                $errors[] = "{$where}: {$e->getMessage()}";
            });
            $read = Evaluate::normalizeState($store->getState('odd'), 'odd');
            $this->assertSame(['', '5', '', 0, null, null, null, null, ['b' => 2], 'run'], [
                $read->undelivered[0]->run->id, $read->undelivered[0]->run->job, $read->undelivered[0]->run->status, $read->undelivered[0]->run->startedAt,
                $read->undelivered[0]->run->finishedAt, $read->undelivered[0]->run->durationMs, $read->undelivered[0]->run->error, $read->undelivered[0]->run->output,
                $read->undelivered[0]->run->metrics, $read->undelivered[0]->run->trigger,
            ]);
            $this->assertSame([0, null], [$read->sending[0]->alert->run->startedAt, $read->sending[0]->alert->run->error]);
            $cw->check();
            $this->assertSame([], $errors);
            $this->assertNotNull($cw->silence('odd', '1h')->silencedUntil);
            $this->assertNull($cw->unsilence('odd')->silencedUntil);
            try {
                $cw->run('odd', function (): never {
                    throw new \RuntimeException('boom');
                });
            } catch (\RuntimeException) {
            }
            $this->assertContains('failed', $sent);
            $this->assertSame([], $errors);
        } finally {
            $backend->done();
        }
    }

    /**
     * A state row whose text is not JSON at all (SQLite's and MySQL's text
     * column can hold any) reads as no state, counts as version 0, and the
     * next write replaces it: the job is checked and can be silenced. Its
     * version is tested before the JSON is read, which would fail on it.
     * Postgres's JSONB cannot hold such text.
     */
    #[DataProvider('stores')]
    public function testAStateRowThatIsNotJsonReadsAsNoneAndTheNextWriteReplacesIt(string $kind): void
    {
        $why = $kind === 'postgres' ? 'JSONB holds only JSON' : Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        $backend = Backend::make($kind);
        try {
            $store = $backend->open();
            $store->init();
            $store->upsertJob(JobDefinition::fromJson(['name' => 'odd']), 1);
            $p = $backend->tables();
            $backend->pdo()->exec("INSERT INTO {$p}state (job, state) VALUES ('odd', '{')");
            $errors = [];
            $cw = new Cronwatch(store: $store, alerts: [], cronSecret: null, now: fn () => 1767605400000, onError: function (\Throwable $e, string $where) use (&$errors): void {
                $errors[] = "{$where}: {$e->getMessage()}";
            });
            $this->assertNull($store->getState('odd'));
            $this->assertSame('never_ran', $cw->check()->jobs[0]->health);
            $this->assertSame([1767609000000, 1], [$cw->silence('odd', '1h')->silencedUntil, $store->getState('odd')?->version]);
            $this->assertSame([], $errors);
        } finally {
            $backend->done();
        }
    }

    /**
     * A queued recovery whose `after` holds an object is stale and dropped,
     * and does not stop the job's new alerts going out (review 2, low 1).
     */
    #[DataProvider('stores')]
    public function testAQueuedRecoveryWhoseAfterHoldsAnObjectIsDroppedAndNewAlertsStillGoOut(string $kind): void
    {
        $why = Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        $backend = Backend::make($kind);
        try {
            $store = $backend->open();
            $store->init();
            $store->upsertJob(JobDefinition::fromJson(['name' => 'odd', 'timeout' => '5m']), 1);
            $p = $backend->tables();
            $recovered = '{"type":"recovered","job":"odd","definition":{"name":"odd"},"run":null,"title":"t","message":"m","at":1,"details":{"after":[{"x":1},"failed"]}}';
            $state = '{"job":"odd","open":{},"consecutiveFailures":0,"silencedUntil":null,"lastAlertAt":null,"pendingRecovery":[],"undelivered":[' . $recovered . ']}';
            $backend->pdo()->exec("INSERT INTO {$p}state (job, state) VALUES ('odd', '{$state}')");
            $trigger = $kind === 'mysql' || $kind === 'mariadb' ? '`trigger`' : 'trigger';
            $backend->pdo()->exec("INSERT INTO {$p}runs (id, job, status, started_at, metrics, {$trigger}) VALUES ('long', 'odd', 'running', 1, '{}', 'run')");
            $sent = [];
            $errors = [];
            $cw = new Cronwatch(store: $store, alerts: [new Custom('capture', function (Alert $alert) use (&$sent): void {
                $sent[] = $alert->type;
            })], cronSecret: null, onError: function (\Throwable $e, string $where) use (&$errors): void {
                $errors[] = "{$where}: {$e->getMessage()}";
            });
            $cw->check();
            $this->assertSame([], $errors);
            $this->assertSame(['stuck'], $sent, 'the stale recovery is dropped, the new alert sent');
            $this->assertSame([], Evaluate::normalizeState($store->getState('odd'), 'odd')->undelivered);
        } finally {
            $backend->done();
        }
    }

    public function testRunDurationAtPhpsIntegerLimits(): void
    {
        $this->assertSame(Evaluate::MAX_DURATION_MS, Evaluate::runDuration(PHP_INT_MIN, 1767605400000));
        $this->assertSame(Evaluate::MAX_DURATION_MS, Evaluate::runDuration(PHP_INT_MIN, PHP_INT_MAX));
        $this->assertSame(0, Evaluate::runDuration(PHP_INT_MAX, 1767605400000));
        $this->assertSame(0, Evaluate::runDuration(PHP_INT_MAX, PHP_INT_MIN));
        $this->assertSame(0, Evaluate::runDuration(NAN, 1767605400000));
        $this->assertSame(1500, Evaluate::runDuration(1767605398500, 1767605400000));
    }

    /**
     * The stuck alert is sent: its text writes a start before the year 1 as
     * words, not as a date.
     */
    #[DataProvider('stores')]
    public function testACheckOverARunThatStartedAtTheLowestBigintAndAStateWhoseVersionIsOnePointFive(string $kind): void
    {
        $why = Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        $backend = Backend::make($kind);
        try {
            $store = $backend->open();
            $store->init();
            $store->upsertJob(JobDefinition::fromJson(['name' => 'far', 'timeout' => '5m']), 1);
            $p = $backend->tables();
            $trigger = $kind === 'mysql' || $kind === 'mariadb' ? '`trigger`' : 'trigger';
            $pdo = $backend->pdo();
            $pdo->exec("INSERT INTO {$p}runs (id, job, status, started_at, metrics, {$trigger}) VALUES ('far1', 'far', 'running', -9223372036854775808, '{}', 'run')");
            $pdo->exec("INSERT INTO {$p}state (job, state) VALUES ('far', '{\"job\":\"far\",\"open\":{},\"consecutiveFailures\":0,\"silencedUntil\":null,\"lastAlertAt\":null,\"version\":1.5}')");
            $sent = [];
            $capture = new Custom('capture', function (Alert $alert) use (&$sent): void {
                $sent[] = $alert;
            });
            $cw = new Cronwatch(store: $store, alerts: [$capture], cronSecret: null, onError: function (\Throwable $e): void {
                throw $e;
            });
            $cw->check();
            $cw->check();
            $run = $store->getRun('far1');
            $this->assertSame(RunStatus::TIMEOUT, $run?->status);
            $this->assertSame(9007199254740991, $run->durationMs, 'the duration is held at 2^53 - 1');
            $state = $store->getState('far');
            $this->assertSame(2, $state?->version, "the state's 1.5 counted as 0, then the timeout and the alert each wrote it");
            $this->assertSame(1, $state->consecutiveFailures);
            $this->assertSame(['stuck'], array_map(fn (Alert $a) => $a->type, $sent));
            $this->assertSame('Started before 0001-01-01 00:00:00 UTC and never reported finishing. Marked as timed out after 104249991d 8h.', explode("\n", $sent[0]->message)[0]);
        } finally {
            $backend->done();
        }
    }

    /**
     * A state whose times, conditions and queued alerts hold values of the
     * wrong kind: each reads as absent, so the job is still checked, its
     * failures still alert, and silence and unsilence still work.
     */
    #[DataProvider('stores')]
    public function testAStateWithOddValuesIsStillEvaluatedAndCanBeSilenced(string $kind): void
    {
        $why = Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        $backend = Backend::make($kind);
        try {
            $store = $backend->open();
            $store->init();
            $store->upsertJob(JobDefinition::fromJson(['name' => 'odd']), 1);
            $p = $backend->tables();
            $alert = '{"type":"failed","job":"odd","definition":{"name":"odd"},"run":"r","title":7,"message":null,"at":"x","triage":5,"details":{}}';
            $state = '{"job":"odd","open":{},"consecutiveFailures":0,"silencedUntil":"soon","lastAlertAt":"x","pendingRecovery":[1,"failed",null],"undelivered":["x",' . $alert . ']}';
            $backend->pdo()->exec("INSERT INTO {$p}state (job, state) VALUES ('odd', '{$state}')");
            $sent = [];
            $capture = new Custom('capture', function (Alert $alert) use (&$sent): void {
                $sent[] = $alert->type;
            });
            $cw = new Cronwatch(store: $store, alerts: [$capture], cronSecret: null, onError: function (\Throwable $e): void {
                throw $e;
            });
            $read = $store->getState('odd');
            $this->assertNull($read->silencedUntil);
            $this->assertNull($read->lastAlertAt);
            $this->assertSame(['failed'], $read->pendingRecovery);
            $this->assertCount(1, $read->undelivered);
            $this->assertSame([0, null, true], [$read->undelivered[0]->at, $read->undelivered[0]->triage, $read->undelivered[0]->triageTried]);
            $cw->check();
            $this->assertSame('never_ran', $cw->jobSummary('odd')->health);
            $this->assertNotNull($cw->silence('odd', '1h')->silencedUntil);
            $this->assertNull($cw->unsilence('odd')->silencedUntil);
            try {
                $cw->run('odd', function (): never {
                    throw new \RuntimeException('boom');
                });
            } catch (\RuntimeException) {
            }
            $this->assertContains('failed', $sent);
        } finally {
            $backend->done();
        }
    }

    /** @return iterable<string, array{string, string}> */
    public static function farCronStarts(): iterable
    {
        foreach (['sqlite', 'mysql', 'mariadb', 'postgres'] as $kind) {
            foreach (['-62135596800001', '253402300800000', '-9223372036854775808', '9223372036854775807'] as $start) {
                yield "{$kind} {$start}" => [$kind, $start];
            }
        }
    }

    /**
     * A cron job's last run as a foreign or damaged row could hold it:
     * before the year 1 (the first fire of the year 1 was missed) or after
     * 9999 (never due again), and at BIGINT's ends. Neither a check nor the
     * dashboard reports an error (cronOverForeignRow in the SDK's
     * stores.test.ts).
     */
    #[DataProvider('farCronStarts')]
    public function testACheckAndTheDashboardOverACronJobWhoseLastRunStartedFarOff(string $kind, string $start): void
    {
        $why = Backend::unavailable($kind);
        if ($why !== null) {
            $this->markTestSkipped($why);
        }
        $backend = Backend::make($kind);
        try {
            $store = $backend->open();
            $store->init();
            $store->upsertJob(JobDefinition::fromJson(['name' => 'far', 'schedule' => '0 2 * * *', 'timezone' => 'UTC', 'grace' => '10m']), 1);
            $p = $backend->tables();
            $trigger = $kind === 'mysql' || $kind === 'mariadb' ? '`trigger`' : 'trigger';
            $backend->pdo()->exec("INSERT INTO {$p}runs (id, job, status, started_at, finished_at, duration_ms, metrics, {$trigger}) VALUES ('far1', 'far', 'ok', {$start}, {$start}, 0, '{}', 'run')");
            $sent = [];
            $errors = [];
            $capture = new Custom('capture', function (Alert $alert) use (&$sent): void {
                $sent[] = $alert;
            });
            $cw = new Cronwatch(store: $store, alerts: [$capture], cronSecret: null, onError: function (\Throwable $e, string $context) use (&$errors): void {
                $errors[] = "{$context}: {$e->getMessage()}";
            });
            $cw->check();
            $web = $cw->routes(token: 'tok', basePath: '/cronwatch');
            foreach (['/cronwatch/', '/cronwatch/jobs/far', '/cronwatch/api/jobs/far'] as $path) {
                $response = $web->handle(Request::create('GET', "http://app.test{$path}", ['authorization' => 'Bearer tok'], ''));
                $this->assertSame(200, $response->status, $path);
            }
            $this->assertSame([], $errors);
            $this->assertSame(str_starts_with($start, '-') ? ['missed'] : [], array_map(fn (Alert $a) => $a->type, $sent));
            if ($sent !== []) {
                $this->assertStringStartsWith('Due 0001-01-01 02:00:00 UTC ', $sent[0]->message);
            }
        } finally {
            $backend->done();
        }
    }
}
