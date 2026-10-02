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
        $cw->job('gone', ['schedule' => '@hourly', 'grace' => '5m', 'description' => 'nightly', 'tags' => ['fw', 'fw:app']]);
        $cw->job('kept', ['schedule' => '@hourly', 'tags' => ['fw', 'fw:app']]);
        $cw->job('other', ['schedule' => '@hourly', 'tags' => ['not-ours']]);
        $cw->job('theirs', ['schedule' => '@hourly', 'tags' => ['fw', 'fw:another-app']]);
        $cw->check();

        $again = $this->make(['store' => $cw->store]);
        $again->job('kept', ['schedule' => '@hourly', 'tags' => ['fw', 'fw:app']]);
        $this->assertSame(['gone'], Unscheduled::declare($again, 'fw', 'fw:app', fn () => null));
        $again->check();
        $gone = $again->store->getJob('gone')->definition;
        $this->assertSame(['description' => 'nightly (no longer scheduled)', 'tags' => ['fw', 'fw:app'], 'grace' => '5m', 'name' => 'gone'], $gone->fields);
        $this->assertTrue($again->store->getJob('kept')->definition->has('schedule'));
        $this->assertTrue($again->store->getJob('other')->definition->has('schedule'), 'another integration\'s job is left alone');
        $this->assertTrue($again->store->getJob('theirs')->definition->has('schedule'), 'and another app\'s');
        $this->assertSame([], Unscheduled::declare($again, 'fw', 'fw:app', fn () => null), 'once');
    }

    public function testAJobTaggedBeforeAppTagsIsTakenOnlyWhileNoOtherAppIsInTheStore(): void
    {
        $cw = $this->make();
        $cw->job('old', ['schedule' => '@hourly', 'tags' => ['team', 'fw']]);
        $cw->check();

        // One app in the store: the old job is its own, declared again with the app's tag.
        $alone = $this->make(['store' => $cw->store]);
        $this->assertSame(['old'], Unscheduled::declare($alone, 'fw', 'fw:app', fn () => null));
        $alone->check();
        $this->assertSame(['team', 'fw', 'fw:app'], $alone->store->getJob('old')->definition->get('tags'));
        $this->assertFalse($alone->store->getJob('old')->definition->has('schedule'));

        // Another app has tagged its jobs: an old job could be either's, and is left alone.
        $shared = $this->make();
        $shared->job('old', ['schedule' => '@hourly', 'tags' => ['fw']]);
        $shared->job('blog', ['schedule' => '@daily', 'tags' => ['fw', 'fw:blog']]);
        $shared->check();
        $shop = $this->make(['store' => $shared->store]);
        $this->assertSame([], Unscheduled::declare($shop, 'fw', 'fw:shop', fn () => null));
        $this->assertTrue($shop->store->getJob('old')->definition->has('schedule'));
        $this->assertTrue($shop->store->getJob('blog')->definition->has('schedule'));
    }

    public function testAppTags(): void
    {
        $this->assertSame('fw:laravel', Unscheduled::appTag('fw', 'Laravel'));
        $this->assertSame('fw:billing-api', Unscheduled::appTag('fw', '  Billing API! '));
        $this->assertSame('fw:app-1d4ce23f0a88', Unscheduled::appTag('fw', 'app-1d4ce23f0a88'));
        $this->assertSame('fw:' . substr(md5('ÉÉ'), 0, 8), Unscheduled::appTag('fw', 'ÉÉ'), 'nothing left once cleaned');
        $long = str_repeat('x', 60);
        $this->assertSame('fw:' . str_repeat('x', 39) . '-' . substr(md5($long), 0, 8), Unscheduled::appTag('fw', $long));
    }

    public function testTheWatchAttribute(): void
    {
        $watch = Watch::of(WatchedChild::class);
        $this->assertNotNull($watch, 'read from the nearest parent');
        $this->assertSame('annotated', $watch->name);
        $this->assertSame(['schedule' => '0 * * * *', 'grace' => '5m', 'budget' => ['cost' => 2], 'tags' => ['team']], $watch->options());
        $this->assertSame(['budget' => ['cost' => 2], 'floor' => ['rows' => 1]], (new Watch(floor: ['rows' => 1], budget: ['cost' => 2]))->options());
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
