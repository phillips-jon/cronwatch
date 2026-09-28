<?php

declare(strict_types=1);

namespace Cronwatch\Tests;

use Cronwatch\Bridge\JobName;
use Cronwatch\Bridge\Unscheduled;
use Cronwatch\Cronwatch;
use Cronwatch\Store\MemoryStore;
use Cronwatch\Store\Migrated;
use Cronwatch\Tests\Support\Clients;
use Cronwatch\Watch;
use PHPUnit\Framework\TestCase;

#[Watch(name: 'annotated', schedule: '0 * * * *', grace: '5m', budget: ['cost' => 2], tags: ['team'])]
class WatchedParent
{
}

final class WatchedChild extends WatchedParent
{
}

#[Watch(enabled: false)]
final class NotWatched
{
}

/**
 * What the Laravel and Symfony integrations share, without either: job
 * names from tasks, jobs no longer scheduled, the #[Watch] attribute, and
 * a store whose tables a migration made.
 */
final class BridgeTest extends TestCase
{
    use Clients;

    public function testJobNamesFromCommandsClassesAndText(): void
    {
        $this->assertSame('emails:send', JobName::clean('emails:send'));
        $this->assertSame('emails:send-force-' . substr(md5('emails:send --force'), 0, 8), JobName::clean('emails:send --force'));
        $this->assertSame('App.Jobs.PruneUsers', JobName::ofClass('App\Jobs\PruneUsers'));
        $this->assertSame('App.Jobs.PruneUsers', JobName::ofClass('\App\Jobs\PruneUsers'));
        $this->assertSame('job-' . substr(md5('   '), 0, 8), JobName::clean('   '));
        $this->assertSame('report-' . substr(md5('--report'), 0, 8), JobName::clean('--report'), 'a name starts with a letter or digit');
        $long = str_repeat('a', 130);
        $cut = JobName::clean($long);
        $this->assertSame(120, strlen($cut));
        $this->assertStringEndsWith('-' . substr(md5($long), 0, 8), $cut);
        foreach (['emails:send --force', 'node /x.js', $long, 'ünïcode task', 'App\Jobs\X'] as $text) {
            $this->assertMatchesRegularExpression(Cronwatch::NAME_PATTERN, JobName::clean($text), $text);
        }
    }

    public function testJobsNoLongerScheduledAreDeclaredAgainWithoutTheirSchedule(): void
    {
        $cw = $this->make();
        $cw->job('gone', ['schedule' => '@hourly', 'grace' => '5m', 'description' => 'nightly', 'tags' => ['fw']]);
        $cw->job('kept', ['schedule' => '@hourly', 'tags' => ['fw']]);
        $cw->job('other', ['schedule' => '@hourly', 'tags' => ['not-ours']]);
        $cw->check();

        $again = $this->make(['store' => $cw->store]);
        $again->job('kept', ['schedule' => '@hourly', 'tags' => ['fw']]);
        $this->assertSame(['gone'], Unscheduled::declare($again, 'fw', fn () => null));
        $again->check();
        $gone = $again->store->getJob('gone')->definition;
        $this->assertSame(['description' => 'nightly (no longer scheduled)', 'tags' => ['fw'], 'grace' => '5m', 'name' => 'gone'], $gone->fields);
        $this->assertTrue($again->store->getJob('kept')->definition->has('schedule'));
        $this->assertTrue($again->store->getJob('other')->definition->has('schedule'), 'another integration\'s job is left alone');
        $this->assertSame([], Unscheduled::declare($again, 'fw', fn () => null), 'once');
    }

    public function testTheWatchAttribute(): void
    {
        $watch = Watch::of(WatchedChild::class);
        $this->assertNotNull($watch, 'read from the nearest parent');
        $this->assertSame('annotated', $watch->name);
        $this->assertSame(['schedule' => '0 * * * *', 'grace' => '5m', 'budget' => ['cost' => 2], 'tags' => ['team']], $watch->options());
        $this->assertFalse(Watch::of(new NotWatched())->enabled);
        $this->assertNull(Watch::of(self::class));
        $this->assertNull(Watch::of('No\Such\ClassName'));
    }

    public function testAMigratedStoreLeavesTheTablesAlone(): void
    {
        $inner = new class () extends \Cronwatch\Tests\Support\DelegatingStore implements \Cronwatch\Store\UpdatesRunIf, \Cronwatch\Store\ComparesAndSetsState {
            public int $inits = 0;

            public function __construct()
            {
                parent::__construct(new MemoryStore());
            }

            public function init(): void
            {
                $this->inits++;
            }

            public function updateRunIf(\Cronwatch\Run $run, array $fromStatuses): bool
            {
                return $this->inner->updateRunIf($run, $fromStatuses);
            }

            public function compareAndSetState(\Cronwatch\JobState $state, int|float $expectedVersion): bool
            {
                return $this->inner->compareAndSetState($state, $expectedVersion);
            }
        };
        $cw = $this->make(['store' => new Migrated($inner)]);
        $cw->job('x')->run(fn () => 'ran');
        $cw->check();
        $this->assertSame(0, $inner->inits);
        $this->assertSame('ran', $cw->runs('x')[0]->output);
    }
}
