<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Cronwatch;
use Cronwatch\JobDefinition;
use Cronwatch\JobState;
use Cronwatch\Js;
use Cronwatch\Run;
use Cronwatch\Store\SqliteStore;
use Cronwatch\Tests\Support\Capture;
use Cronwatch\Tests\Support\Clock;
use Cronwatch\Tests\Support\Node;
use PHPUnit\Framework\TestCase;

/**
 * A Node process and a PHP process sharing one SQLite file: the SDK's store
 * (from the built packages/sdk/dist, driven by tests/node/node_store.mjs)
 * and SqliteStore replay the same store calls (fixtures/shared_store.json, a
 * copy of the Ruby and Python tests' fixture), and each must read what the
 * other wrote exactly as it reads its own, down to the bytes in every column.
 */
final class NodeCompatTest extends TestCase
{
    private const FIXTURE = __DIR__ . '/fixtures/shared_store.json';

    private string $dir;

    protected function setUp(): void
    {
        $why = Node::unavailable(sqlite: true);
        if ($why !== null) {
            $this->markTestSkipped("Node compatibility: {$why}");
        }
        $this->dir = sys_get_temp_dir() . '/cronwatch-node-' . getmypid() . '-' . bin2hex(random_bytes(4));
        mkdir($this->dir);
    }

    protected function tearDown(): void
    {
        if (isset($this->dir)) {
            foreach (glob("{$this->dir}/*") ?: [] as $file) {
                unlink($file);
            }
            rmdir($this->dir);
        }
    }

    private static function fixture(): \stdClass
    {
        return Js::parse((string) file_get_contents(self::FIXTURE));
    }

    private static function node(string $action, string $file, string $prefix, string ...$args): string
    {
        return Node::run('node_store.mjs', $action, $file, $prefix, ...$args);
    }

    private static function nodeWrite(string $file, string $prefix): \stdClass
    {
        return Js::parse(self::node('write', $file, $prefix, self::FIXTURE));
    }

    private static function phpWrite(SqliteStore $store): array
    {
        $store->init();
        $pruned = [];
        foreach (self::fixture()->ops as $step) {
            match ($step->op) {
                'upsertJob' => $store->upsertJob(JobDefinition::fromJson($step->definition), $step->now),
                'insertRun' => $store->insertRun(Run::fromJson($step->run)),
                'updateRun' => $store->updateRun(Run::fromJson($step->run)),
                'setState' => $store->setState(JobState::fromJson($step->state)),
                'deleteJob' => $store->deleteJob($step->name),
                'prune' => $pruned[] = $store->prune($step->before),
            };
        }
        return ['pruned' => $pruned];
    }

    /** What node_store.mjs `read` prints, from the PHP store, in the same key order. */
    private static function phpRead(SqliteStore $store): string
    {
        $read = self::fixture()->read;
        $out = ['jobs' => $store->listJobs(), 'job' => [], 'runs' => [], 'limited' => [], 'last' => [], 'state' => []];
        foreach ($read->jobs as $name) {
            $out['job'][$name] = $store->getJob($name);
            $out['runs'][$name] = $store->listRuns($name, 100);
            $out['limited'][$name] = $store->listRuns($name, 1);
            $out['last'][$name] = $store->lastRun($name);
            $out['state'][$name] = $store->getState($name);
        }
        $out['running'] = $store->runningRuns();
        $out['run'] = [];
        foreach ($read->runs as $id) {
            $out['run'][$id] = $store->getRun($id);
        }
        return Js::stringify($out);
    }

    /** Every row of the three tables, with each value's SQLite type, JSON columns as the text the database holds. */
    private static function rawRows(string $file, string $prefix): array
    {
        $db = new \PDO("sqlite:{$file}");
        $typed = fn (string $column) => "{$column}, typeof({$column})";
        $runs = implode(', ', array_map($typed, ['id', 'job', 'status', 'started_at', 'finished_at', 'duration_ms', 'error', 'output', 'metrics', 'trigger']));
        return [
            'jobs' => $db->query("SELECT {$typed('name')}, {$typed('definition')}, {$typed('created_at')}, {$typed('updated_at')} FROM {$prefix}jobs ORDER BY created_at, name")->fetchAll(\PDO::FETCH_NUM),
            'runs' => $db->query("SELECT rowid, {$runs} FROM {$prefix}runs ORDER BY rowid")->fetchAll(\PDO::FETCH_NUM),
            'state' => $db->query("SELECT {$typed('job')}, {$typed('state')} FROM {$prefix}state ORDER BY job")->fetchAll(\PDO::FETCH_NUM),
        ];
    }

    private static function schemaOf(string $file, string $prefix): array
    {
        $db = new \PDO("sqlite:{$file}");
        $statement = $db->prepare('SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name LIKE ? ORDER BY name');
        $statement->execute(["{$prefix}%"]);
        return array_map(fn (array $row) => array_map(fn ($v) => str_replace($prefix, 'PREFIX_', (string) $v), $row), $statement->fetchAll(\PDO::FETCH_NUM));
    }

    public function testPhpReadsWhatNodeWrote(): void
    {
        $file = "{$this->dir}/shared.db";
        $this->assertSame([1], self::nodeWrite($file, 'cw_')->pruned);
        $store = new SqliteStore($file, prefix: 'cw_');
        $nodeView = self::node('read', $file, 'cw_', self::FIXTURE);
        $this->assertStringNotContainsString('never stored', $nodeView);
        $this->assertSame($nodeView, self::phpRead($store));
        $store->close();
    }

    public function testNodeReadsWhatPhpWroteAndTheRowsAreTheSame(): void
    {
        $nodeFile = "{$this->dir}/node.db";
        $phpFile = "{$this->dir}/php.db";
        $written = self::nodeWrite($nodeFile, 'cw_');
        $store = new SqliteStore($phpFile, prefix: 'cw_');
        $this->assertSame(Js::stringify($written), Js::stringify(self::phpWrite($store)));
        $store->close();
        $this->assertSame(self::node('read', $nodeFile, 'cw_', self::FIXTURE), self::node('read', $phpFile, 'cw_', self::FIXTURE), "Node reads PHP's rows as it reads its own");
        $this->assertSame(self::rawRows($nodeFile, 'cw_'), self::rawRows($phpFile, 'cw_'), 'the same bytes, and the same types, in every column');
    }

    public function testTheTablesAreTheSameWhoeverCreatesThem(): void
    {
        $file = "{$this->dir}/both.db";
        self::nodeWrite($file, 'node_');
        $store = new SqliteStore($file, prefix: 'php_');
        $store->init();
        $store->close();
        $this->assertSame(self::schemaOf($file, 'node_'), self::schemaOf($file, 'php_'));
    }

    public function testNodeCarriesOnFromPhpAndPhpFromNode(): void
    {
        $file = "{$this->dir}/shared.db";
        self::nodeWrite($file, 'cw_');
        $store = new SqliteStore($file, prefix: 'cw_');
        // A PHP client finishes a run of a job Node wrote, and checks every job.
        $clock = new Clock(1_767_606_100_000);
        $client = new Cronwatch(store: $store, now: $clock, alerts: [new Capture()], cronSecret: null);
        $client->job('every-5', ['schedule' => 'every 5m', 'timeout' => '2m', 'maxDuration' => '90s'])->run(fn ($ctx) => $ctx->log('from php'));
        $clock->advance(10 * Clock::MIN);
        $result = $client->check();
        $this->assertContains('nightly-report', array_map(fn ($j) => $j->name, $result->jobs));
        $this->assertSame('from php', $store->lastRun('every-5')->output);
        $nodeView = Js::parse(self::node('read', $file, 'cw_', self::FIXTURE));
        $this->assertSame('from php', $nodeView->last->{'every-5'}->output);
        $this->assertSame(array_keys(get_object_vars($nodeView->state->{'every-5'})), array_keys($store->getState('every-5')->toJson()));
        $this->assertSame(Js::stringify($nodeView), self::phpRead($store));

        // And Node takes a turn on the same file: PHP reads its run and state.
        $clock->advance(10 * Clock::MIN);
        $nodeRun = Js::parse(self::node('run', $file, 'cw_', (string) $clock->now));
        $this->assertContains('every-5', $nodeRun->jobs);
        $this->assertSame('from node', $store->lastRun('every-5')->output);
        $this->assertSame(Js::stringify(Js::parse(self::node('read', $file, 'cw_', self::FIXTURE))), self::phpRead($store));
        $this->assertContains('every-5', array_map(fn ($j) => $j->name, $client->check()->jobs));
        $store->close();
    }

    public function testNodeAndPhpTakeTurnsOnOneJobsStateVersion(): void
    {
        $file = "{$this->dir}/versions.db";
        $store = new SqliteStore($file, prefix: 'cw_');
        $store->init();
        $v = fn (int $version, int $failures, string $job = 'v') => new JobState($job, [], $failures, null, null, null, null, $version);
        $nodeCas = fn (JobState $state, int $expected) => Js::parse(self::node('cas', $file, 'cw_', Js::stringify($state), (string) $expected));

        $this->assertTrue($store->compareAndSetState($v(1, 1), 0), 'PHP writes the first version');
        $this->assertFalse($nodeCas($v(1, 9), 0)->written, "Node's write from before it is refused");
        $fresh = $nodeCas($v(2, 2), 1);
        $this->assertTrue($fresh->written);
        $this->assertSame(2, $fresh->state->version);
        $this->assertFalse($store->compareAndSetState($v(2, 7), 1), "PHP's stale write is refused");
        $this->assertTrue($store->compareAndSetState($v(3, 3), 2));
        $late = $nodeCas($v(3, 0), 2);
        $this->assertSame([false, 3, 3], [$late->written, $late->state->version, $late->state->consecutiveFailures], "Node reads PHP's version");
        $this->assertSame(Js::stringify($late->state), Js::stringify($store->getState('v')));

        // State written before versions existed counts as 0 for both.
        $store->setState(new JobState('old', [], 4));
        $this->assertTrue($nodeCas($v(1, 5, 'old'), 0)->written);
        $this->assertSame(1, $store->getState('old')->version);
        $store->close();
    }
}
