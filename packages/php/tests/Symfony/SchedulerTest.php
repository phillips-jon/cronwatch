<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Symfony;

use Cronwatch\Cronwatch;
use Cronwatch\Symfony\CheckMessage;
use Cronwatch\Symfony\ScheduledMessages;
use Cronwatch\Tests\Symfony\Fixtures\AsyncReport;
use Cronwatch\Tests\Symfony\Fixtures\Failing;
use Cronwatch\Tests\Symfony\Fixtures\Handlers;
use Cronwatch\Tests\Symfony\Fixtures\Plain;
use Cronwatch\Tests\Symfony\Fixtures\RedispatchedReport;
use Cronwatch\Tests\Symfony\Fixtures\Report;
use Cronwatch\Tests\Symfony\Fixtures\ReportsSchedule;
use Cronwatch\Tests\Symfony\Fixtures\TestSchedule;
use Symfony\Bundle\FrameworkBundle\Console\Application;
use Symfony\Component\Console\Messenger\RunCommandMessage;
use Symfony\Component\Console\Tester\CommandTester;
use Symfony\Component\Messenger\Message\RedispatchMessage;
use Symfony\Component\Messenger\MessageBusInterface;
use Symfony\Component\Scheduler\Messenger\ServiceCallMessage;
use Symfony\Component\Scheduler\RecurringMessage;
use Symfony\Component\Scheduler\Trigger\CallbackTrigger;

/**
 * Symfony Scheduler and Messenger: how each recurring message becomes a
 * job, its runs recorded by a real worker (messenger:consume), Messenger
 * messages marked #[Watch] with their retries, and the check.
 */
final class SchedulerTest extends TestCase
{
    /** The test kernel's app tag: a hash of its project directory, when no app_id is set. */
    private static function appTag(): string
    {
        return 'symfony-scheduler:app-' . substr(hash('sha256', 'cronwatch:dir:' . static::getContainer()->getParameter('kernel.project_dir')), 0, 12);
    }

    protected function tearDown(): void
    {
        TestSchedule::$messages = [];
        ReportsSchedule::$messages = [];
        Handlers::$asyncCalls = 0;
        Handlers::$succeedOn = 3;
        parent::tearDown();
    }

    /** @return array<string, array<string, mixed>> */
    private function declared(Cronwatch $cw): array
    {
        static::getContainer()->get(ScheduledMessages::class)->declare();
        $out = [];
        foreach ($cw->definedJobs() as $definition) {
            $out[(string) $definition->get('name')] = $definition->fields;
        }
        return $out;
    }

    private function consume(string $transport, int $limit, int $seconds = 5): string
    {
        $application = new Application(static::$kernel);
        $tester = new CommandTester($application->find('messenger:consume'));
        $tester->execute(['receivers' => [$transport], '--limit' => (string) $limit, '--time-limit' => (string) $seconds, '--sleep' => '0.05', '--no-reset' => null]);
        return $tester->getDisplay();
    }

    public function testAMessagesOwnDescriptionWinsOverTheDefault(): void
    {
        [, $given] = \Cronwatch\Symfony\MessengerSubscriber::definition(Report::class, new \Cronwatch\Watch(description: 'Builds the nightly report'));
        $this->assertSame('Builds the nightly report', $given['description']);
        [, $plain] = \Cronwatch\Symfony\MessengerSubscriber::definition(Report::class, new \Cronwatch\Watch());
        $this->assertSame('Message ' . Report::class, $plain['description']);
    }

    public function testEveryKindOfRecurringMessageIsAJobNamedAsDesignMdSays(): void
    {
        TestSchedule::$messages = [
            RecurringMessage::cron('0 2 * * *', new Report(), 'Europe/Paris'),
            RecurringMessage::every('1 hour', new Plain('a')),
            RecurringMessage::every('10 minutes', new RunCommandMessage('app:prune --days=30')),
            RecurringMessage::cron('*/5 * * * *', new ServiceCallMessage('app.cleaner', 'purge')),
            RecurringMessage::cron('@daily', new ServiceCallMessage('App\Service\Nightly')),
            RecurringMessage::every('30 seconds', new RedispatchMessage(new RedispatchedReport(), 'async')),
            RecurringMessage::every('1 month', new Failing()),
            RecurringMessage::every('2 hours', new AsyncReport())->withJitter(30),
        ];
        ReportsSchedule::$messages = [RecurringMessage::cron('*/15 * * * *', new Plain('b'))];
        self::bootKernel();
        $cw = $this->client();
        $jobs = $this->declared($cw);
        $plain = 'Cronwatch.Tests.Symfony.Fixtures.Plain';
        $this->assertSame([
            'nightly-report', $plain, 'app:prune-days-30-' . substr(md5('app:prune --days=30'), 0, 8), 'app.cleaner.purge', 'App.Service.Nightly',
            'queued-report', 'Cronwatch.Tests.Symfony.Fixtures.Failing', 'Cronwatch.Tests.Symfony.Fixtures.AsyncReport', "reports:{$plain}",
        ], array_keys($jobs));
        $this->assertSame(['schedule' => '0 2 * * *', 'timezone' => 'Europe/Paris', 'description' => Report::class, 'grace' => '15m', 'expect' => 'Report written', 'tags' => ['symfony-scheduler', self::appTag()], 'name' => 'nightly-report'], $jobs['nightly-report']);
        $this->assertSame(['schedule' => 'every 1h', 'description' => Plain::class, 'tags' => ['symfony-scheduler', self::appTag()], 'name' => $plain], $jobs[$plain]);
        $this->assertSame('app:prune --days=30', $jobs['app:prune-days-30-' . substr(md5('app:prune --days=30'), 0, 8)]['description']);
        $this->assertSame(['*/5 * * * *', 'UTC'], [$jobs['app.cleaner.purge']['schedule'], $jobs['app.cleaner.purge']['timezone']]);
        $this->assertSame('0 0 * * *', $jobs['App.Service.Nightly']['schedule']);
        $this->assertSame('every 30s', $jobs['queued-report']['schedule']);
        $this->assertArrayNotHasKey('schedule', $jobs['Cronwatch.Tests.Symfony.Fixtures.Failing'], 'a calendar interval has no fixed length');
        $this->assertSame('every 2h', $jobs['Cronwatch.Tests.Symfony.Fixtures.AsyncReport']['schedule'], 'jitter is read through');
        $this->assertSame('*/15 * * * *', $jobs["reports:{$plain}"]['schedule']);
        $this->assertSame(['declaring Cronwatch.Tests.Symfony.Fixtures.Failing'], $this->wheres());
    }

    public function testAPeriodicMessageOutsideItsFromAndUntilHasNoSchedule(): void
    {
        // The test clock is 2026-01-05 09:30Z.
        TestSchedule::$messages = [
            RecurringMessage::every('1 day', new Plain('ended'), until: '2026-01-01T00:00:00Z'),
            RecurringMessage::every('1 hour', new Report(), from: '2026-02-01T00:00:00Z'),
            RecurringMessage::every('2 hours', new Failing(), from: '2025-12-01T00:00:00Z', until: '2026-03-01T00:00:00Z'),
            RecurringMessage::every('30 minutes', new AsyncReport(), until: '2026-01-02T00:00:00Z')->withJitter(30),
        ];
        self::bootKernel();
        $cw = $this->client();
        $jobs = $this->declared($cw);
        $this->assertArrayNotHasKey('schedule', $jobs['Cronwatch.Tests.Symfony.Fixtures.Plain'], 'its until has passed');
        $this->assertArrayNotHasKey('schedule', $jobs['nightly-report'], 'its from is still to come');
        $this->assertSame('every 2h', $jobs['Cronwatch.Tests.Symfony.Fixtures.Failing']['schedule'], 'inside its window');
        $this->assertArrayNotHasKey('schedule', $jobs['Cronwatch.Tests.Symfony.Fixtures.AsyncReport'], 'read through the jitter');
        $messages = $this->messages();
        $this->assertContains('the trigger "every 1 day" ended at 2026-01-01T00:00:00+00:00, so the job is watched without a schedule', $messages);
        $this->assertContains('the trigger "every 1 hour" starts at 2026-02-01T00:00:00+00:00, so the job is watched without a schedule', $messages);
        $this->assertCount(3, $messages);

        // Never reported missed after it ended.
        $this->clock->advance(3 * 86_400_000);
        $cw->check();
        $this->assertSame([], $this->capture->types());
    }

    public function testCollisionsExclusionsAndConfiguredOptions(): void
    {
        TestSchedule::$messages = [
            RecurringMessage::every('1 hour', new Plain('a')),
            RecurringMessage::every('2 hours', new Plain('b')),
            RecurringMessage::cron('0 3 * * *', new Report()),
            RecurringMessage::trigger(new CallbackTrigger(fn (\DateTimeImmutable $at) => $at->modify('+1 hour')), new Failing()),
            RecurringMessage::every('5 minutes', new CheckMessage()),
        ];
        self::bootKernel(['cronwatch' => ['store' => 'memory', 'scheduler' => [
            'exclude' => ['nightly-report'],
            'jobs' => ['Cronwatch.Tests.Symfony.Fixtures.Failing' => ['name' => 'callback', 'schedule' => '0 * * * *', 'grace' => '5m']],
        ]]]);
        $cw = $this->client();
        $jobs = $this->declared($cw);
        $this->assertSame(['Cronwatch.Tests.Symfony.Fixtures.Plain', 'callback'], array_keys($jobs), 'excluded, and the check is never a job');
        $this->assertArrayNotHasKey('schedule', $jobs['Cronwatch.Tests.Symfony.Fixtures.Plain']);
        $this->assertSame(['0 * * * *', '5m'], [$jobs['callback']['schedule'], $jobs['callback']['grace']]);
        $this->assertStringContainsString('2 scheduled messages are named Cronwatch.Tests.Symfony.Fixtures.Plain, on different schedules', implode("\n", $this->messages()));
    }

    public function testAWorkerRecordsEachScheduledMessagesRun(): void
    {
        TestSchedule::$messages = [
            RecurringMessage::every('1 second', new Report()),
            RecurringMessage::every('1 second', new Failing()),
        ];
        self::bootKernel();
        $cw = $this->client();
        $this->consume('scheduler_default', 2);
        $report = $cw->runs('nightly-report');
        $this->assertNotEmpty($report);
        $this->assertSame(['ok', 'symfony-scheduler', 'Report written', ['pages' => 12]], [$report[0]->status, $report[0]->trigger, $report[0]->output, $report[0]->metrics]);
        $failing = $cw->runs('Cronwatch.Tests.Symfony.Fixtures.Failing');
        $this->assertNotEmpty($failing);
        $this->assertSame('failed', $failing[0]->status);
        $this->assertStringStartsWith("RuntimeException: the report service is down\n    at ", $failing[0]->error, 'the handler\'s exception, out of HandlerFailedException');
        $this->assertNull(Cronwatch::current());
    }

    public function testAMessengerMessageIsRecordedWhereItIsHandledWithEachAttemptARun(): void
    {
        self::bootKernel();
        $cw = $this->client();
        $bus = static::getContainer()->get(MessageBusInterface::class);
        $bus->dispatch(new AsyncReport());
        $this->assertSame([], $cw->runs('Cronwatch.Tests.Symfony.Fixtures.AsyncReport'), 'the dispatch is not the run');
        // Messenger retries it twice (max_retries 2, no delay); the third attempt works.
        $this->consume('async', 3);
        $runs = array_reverse($cw->runs('Cronwatch.Tests.Symfony.Fixtures.AsyncReport'));
        $this->assertSame(['failed', 'failed', 'ok'], array_map(fn ($r) => $r->status, $runs));
        $this->assertSame(['symfony-messenger', 'symfony-messenger', 'symfony-messenger'], array_map(fn ($r) => $r->trigger, $runs));
        $this->assertStringStartsWith('RuntimeException: attempt 1 failed', $runs[0]->error);
        $this->assertSame('attempt 3 worked', $runs[2]->output);
        $this->assertSame(['failed', 'recovered'], $this->capture->types());
    }

    public function testAMessageTheScheduleSendsOnIsTheHandlersRunUnderItsSchedule(): void
    {
        TestSchedule::$messages = [RecurringMessage::every('1 second', new RedispatchMessage(new RedispatchedReport(), 'async'))];
        self::bootKernel();
        // The worker's scheduler starts the trigger at its own time (its
        // `from`), as the app's clock and the client's are one: so is this one.
        $cw = $this->client(['now' => fn (): float => microtime(true) * 1000]);
        // One worker on both transports: the schedule sends the message on, then the worker handles it.
        $application = new Application(static::$kernel);
        $tester = new CommandTester($application->find('messenger:consume'));
        $tester->execute(['receivers' => ['scheduler_default', 'async'], '--limit' => '2', '--time-limit' => '5', '--sleep' => '0.05', '--no-reset' => null]);
        $runs = $cw->runs('queued-report');
        $this->assertSame([['ok', 'symfony-messenger', 'sent on and handled']], array_map(fn ($r) => [$r->status, $r->trigger, $r->output], $runs));
        $this->assertSame('every 1s', $cw->store->getJob('queued-report')->definition->get('schedule'));
    }

    public function testTheCheckCommandDeclaresEveryMessageAndReportsOneThatNeverRan(): void
    {
        TestSchedule::$messages = [RecurringMessage::cron('0 * * * *', new Plain())];
        self::bootKernel();
        $cw = $this->client();
        $application = new Application(static::$kernel);
        $tester = new CommandTester($application->find('cronwatch:check'));
        $tester->execute([]);
        $this->assertSame("cronwatch: checked 1 job, sent 0 alerts\n", $tester->getDisplay());
        $this->clock->advance(2 * 3600_000);
        $tester->execute([]);
        $this->assertSame("cronwatch: checked 1 job, sent 1 alert\n", $tester->getDisplay());
        $this->assertSame(0, $tester->getStatusCode());

        // The message is taken out of the schedule: its job is declared again without one, and missed recovers.
        TestSchedule::$messages = [];
        $store = $cw->store;
        self::ensureKernelShutdown();
        self::bootKernel();
        $cw = $this->client(['store' => $store]);
        $tester = new CommandTester((new Application(static::$kernel))->find('cronwatch:check'));
        $tester->execute([]);
        $this->assertSame("cronwatch: checked 1 job, sent 1 alert\n", $tester->getDisplay());
        $this->assertSame(['recovered'], $this->capture->types());
        $this->assertFalse($cw->store->getJob('Cronwatch.Tests.Symfony.Fixtures.Plain')->definition->has('schedule'));
    }

    public function testTwoAppsSharingAStoreNeverUnscheduleEachOthersJobs(): void
    {
        $check = function (string $app, array $messages, ?\Cronwatch\Store\Store $store): Cronwatch {
            TestSchedule::$messages = $messages;
            self::ensureKernelShutdown();
            self::bootKernel(['cronwatch' => ['store' => 'memory', 'app_id' => $app]]);
            $cw = $this->client($store === null ? [] : ['store' => $store]);
            $tester = new CommandTester((new Application(static::$kernel))->find('cronwatch:check'));
            $tester->execute([]);
            $this->assertSame(0, $tester->getStatusCode());
            return $cw;
        };
        $plain = 'Cronwatch.Tests.Symfony.Fixtures.Plain';
        $shop = $check('Shop', [RecurringMessage::cron('0 * * * *', new Plain())], null);
        $store = $shop->store;
        $this->assertSame(['symfony-scheduler', 'symfony-scheduler:shop'], $store->getJob($plain)->definition->get('tags'));
        $check('Blog', [RecurringMessage::cron('0 2 * * *', new Report())], $store);
        $this->assertTrue($store->getJob($plain)->definition->has('schedule'), 'the blog leaves the shop\'s job alone');
        $this->assertSame(['symfony-scheduler', 'symfony-scheduler:blog'], $store->getJob('nightly-report')->definition->get('tags'));
        $check('Shop', [RecurringMessage::cron('0 * * * *', new Plain())], $store);
        $this->assertTrue($store->getJob('nightly-report')->definition->has('schedule'), 'and the shop the blog\'s');
        $check('Blog', [], $store);
        $this->assertFalse($store->getJob('nightly-report')->definition->has('schedule'), 'the blog\'s own job taken out');
        $this->assertTrue($store->getJob($plain)->definition->has('schedule'));
        $check('Shop', [], $store);
        $this->assertFalse($store->getJob($plain)->definition->has('schedule'));
    }

    /**
     * The tag is on the dashboard and in the API, so nothing secret goes
     * into it: before 0.11 it was 48 bits of a fast hash of APP_SECRET.
     */
    public function testTheDefaultTagIsTheProjectDirectorysNeverTheSecrets(): void
    {
        $secret = new \Symfony\Component\DependencyInjection\ParameterBag\ParameterBag(['kernel.secret' => 'weak-secret']);
        $dir = 'symfony-scheduler:app-' . substr(hash('sha256', 'cronwatch:dir:/srv/shop'), 0, 12);
        $this->assertSame($dir, (new ScheduledMessages(fn () => $this->client(), [], [], true, null, $secret, '/srv/shop'))->appTag());
        // A deploy tool's release directory is read as its root, so the tag outlives a deploy.
        foreach (['/srv/shop/releases/20261001120000', '/srv/shop/releases/42/'] as $release) {
            $this->assertSame($dir, (new ScheduledMessages(fn () => $this->client(), [], [], true, null, $secret, $release))->appTag(), $release);
        }
    }

    public function testJobsTaggedFromTheSecretBefore10AreStillThisAppsOwn(): void
    {
        $secret = new \Symfony\Component\DependencyInjection\ParameterBag\ParameterBag(['kernel.secret' => 'weak-secret']);
        $old = 'symfony-scheduler:app-' . substr(hash('sha256', 'cronwatch:secret:weak-secret'), 0, 12);
        $store = new \Cronwatch\Store\MemoryStore();
        // An earlier release declared a job, tagged from the secret, and another app one of its own.
        $before = new Cronwatch(store: $store, alerts: [], cronSecret: null);
        $before->job('gone', ['schedule' => '0 * * * *', 'tags' => ['symfony-scheduler', $old]]);
        $before->job('theirs', ['schedule' => '0 * * * *', 'tags' => ['symfony-scheduler', 'symfony-scheduler:blog']]);
        $before->check();
        $cw = $this->client(['store' => $store]);
        (new ScheduledMessages(fn () => $cw, [], [], true, null, $secret, '/srv/shop'))->prepare();
        $cw->check();
        $this->assertFalse($store->getJob('gone')->definition->has('schedule'), 'taken out of the schedule, it is declared without it');
        $this->assertTrue($store->getJob('theirs')->definition->has('schedule'), 'another app\'s job is left alone');
        $this->assertSame([], $this->errors);
    }

    public function testWithoutAnAppIdOrASecretTheProjectDirectoryNamesTheApp(): void
    {
        $messages = new ScheduledMessages(fn () => $this->client(), [], [], true, null, null, '/srv/app');
        $this->assertSame('symfony-scheduler:app-' . substr(hash('sha256', 'cronwatch:dir:/srv/app'), 0, 12), $messages->appTag());
        $named = new ScheduledMessages(fn () => $this->client(), [], [], true, 'Shop', null, '/srv/app');
        $this->assertSame('symfony-scheduler:shop', $named->appTag());
    }

    public function testTheCheckIsInTheAppsDefaultSchedule(): void
    {
        self::bootKernel();
        $cw = $this->client();
        $cw->job('seen', ['schedule' => '@hourly']);
        // The check is in the app's default schedule, beside its own messages, so
        // the worker that consumes scheduler_default runs it.
        TestSchedule::$messages = [RecurringMessage::cron('0 * * * *', new Plain())];
        $provider = static::getContainer()->get(TestSchedule::class);
        $this->assertInstanceOf(\Cronwatch\Symfony\CheckSchedule::class, $provider, 'the app\'s provider, decorated');
        $messages = $provider->getSchedule()->getRecurringMessages();
        $this->assertSame(['0 * * * *', 'every 5 minutes'], array_map(fn (RecurringMessage $m) => (string) $m->getTrigger(), $messages));
        $this->assertCount(2, $provider->getSchedule()->getRecurringMessages(), 'added once');
        $this->assertSame(['schedules' => ['default' => 1, 'reports' => 0], 'check' => ['default']], static::getContainer()->get(ScheduledMessages::class)->status());
        $tester = new CommandTester((new Application(static::$kernel))->find('cronwatch:check'));
        $tester->execute(['--status' => true]);
        $this->assertSame(
            "cronwatch: the check runs every 5 minutes in the \"default\" schedule, only while a worker consumes it: bin/console messenger:consume scheduler_default\n"
            . "cronwatch: schedule \"default\" (scheduler_default): 1 message watched, and the check\n"
            . "cronwatch: schedule \"reports\" (scheduler_reports): 0 messages watched\n",
            $tester->getDisplay(),
        );
        $this->assertSame([], $cw->store->listJobs(), '--status checks nothing');
        $handled = static::getContainer()->get(MessageBusInterface::class)->dispatch(new CheckMessage());
        $result = $handled->last(\Symfony\Component\Messenger\Stamp\HandledStamp::class)->getResult();
        $this->assertSame('cronwatch: checked 2 jobs, sent 0 alerts', $result->summary());
    }

    public function testTheCheckCanGoInAScheduleOfItsOwnOrNone(): void
    {
        self::bootKernel(['cronwatch' => ['store' => 'memory', 'check' => ['schedule' => 'cronwatch', 'frequency' => '*/10 * * * *']]]);
        $container = static::getContainer();
        $this->assertTrue($container->has('messenger.transport.scheduler_cronwatch'), 'a schedule of its own gets its transport');
        $this->assertSame(['cronwatch' => 0, 'default' => 0, 'reports' => 0], array_intersect_key($container->get(ScheduledMessages::class)->status()['schedules'], ['default' => 1, 'reports' => 1, 'cronwatch' => 1]));
        $tester = new CommandTester((new Application(static::$kernel))->find('cronwatch:check'));
        $tester->execute(['--status' => true]);
        $this->assertStringStartsWith("cronwatch: the check runs every */10 * * * * in the \"cronwatch\" schedule, only while a worker consumes it: bin/console messenger:consume scheduler_cronwatch\n", $tester->getDisplay());
        self::ensureKernelShutdown();

        self::bootKernel(['cronwatch' => ['store' => 'memory', 'check' => ['schedule' => false]]]);
        $tester = new CommandTester((new Application(static::$kernel))->find('cronwatch:check'));
        $tester->execute(['--status' => true]);
        $this->assertStringStartsWith('cronwatch: the check is not scheduled (check.schedule: false): run bin/console cronwatch:check every five minutes from a crontab', $tester->getDisplay());
        $this->assertSame([], static::getContainer()->get(ScheduledMessages::class)->status()['check']);
        self::ensureKernelShutdown();

        $this->expectException(\Symfony\Component\Config\Definition\Exception\InvalidConfigurationException::class);
        self::bootKernel(['cronwatch' => ['store' => 'memory', 'check' => ['schedule' => 'not a name']]]);
    }

    public function testWatchingCanBeTurnedOff(): void
    {
        TestSchedule::$messages = [RecurringMessage::every('1 second', new Report())];
        self::bootKernel(['cronwatch' => ['store' => 'memory', 'scheduler' => ['watch' => false], 'messenger' => ['watch' => false], 'check' => ['schedule' => false]]]);
        $cw = $this->client();
        $this->consume('scheduler_default', 1);
        static::getContainer()->get(MessageBusInterface::class)->dispatch(new AsyncReport());
        Handlers::$succeedOn = 1;
        $this->consume('async', 1);
        $this->assertSame([], $cw->jobs());
        $this->assertFalse(static::getContainer()->has('Cronwatch\Symfony\CheckSchedule'));
    }
}
