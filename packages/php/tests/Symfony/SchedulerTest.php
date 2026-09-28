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
        $this->assertSame(['schedule' => '0 2 * * *', 'timezone' => 'Europe/Paris', 'description' => Report::class, 'grace' => '15m', 'expect' => 'Report written', 'tags' => ['symfony-scheduler'], 'name' => 'nightly-report'], $jobs['nightly-report']);
        $this->assertSame(['schedule' => 'every 3600s', 'description' => Plain::class, 'tags' => ['symfony-scheduler'], 'name' => $plain], $jobs[$plain]);
        $this->assertSame('app:prune --days=30', $jobs['app:prune-days-30-' . substr(md5('app:prune --days=30'), 0, 8)]['description']);
        $this->assertSame(['*/5 * * * *', 'UTC'], [$jobs['app.cleaner.purge']['schedule'], $jobs['app.cleaner.purge']['timezone']]);
        $this->assertSame('0 0 * * *', $jobs['App.Service.Nightly']['schedule']);
        $this->assertSame('every 30s', $jobs['queued-report']['schedule']);
        $this->assertArrayNotHasKey('schedule', $jobs['Cronwatch.Tests.Symfony.Fixtures.Failing'], 'a calendar interval has no fixed length');
        $this->assertSame('every 7200s', $jobs['Cronwatch.Tests.Symfony.Fixtures.AsyncReport']['schedule'], 'jitter is read through');
        $this->assertSame('*/15 * * * *', $jobs["reports:{$plain}"]['schedule']);
        $this->assertSame(['declaring Cronwatch.Tests.Symfony.Fixtures.Failing'], $this->wheres());
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
        $this->assertSame(['ok', 'scheduler', 'Report written', ['pages' => 12]], [$report[0]->status, $report[0]->trigger, $report[0]->output, $report[0]->metrics]);
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
        $this->assertSame(['messenger', 'messenger', 'messenger'], array_map(fn ($r) => $r->trigger, $runs));
        $this->assertStringStartsWith('RuntimeException: attempt 1 failed', $runs[0]->error);
        $this->assertSame('attempt 3 worked', $runs[2]->output);
        $this->assertSame(['failed', 'recovered'], $this->capture->types());
    }

    public function testAMessageTheScheduleSendsOnIsTheHandlersRunUnderItsSchedule(): void
    {
        TestSchedule::$messages = [RecurringMessage::every('1 second', new RedispatchMessage(new RedispatchedReport(), 'async'))];
        self::bootKernel();
        $cw = $this->client();
        // One worker on both transports: the schedule sends the message on, then the worker handles it.
        $application = new Application(static::$kernel);
        $tester = new CommandTester($application->find('messenger:consume'));
        $tester->execute(['receivers' => ['scheduler_default', 'async'], '--limit' => '2', '--time-limit' => '5', '--sleep' => '0.05', '--no-reset' => null]);
        $runs = $cw->runs('queued-report');
        $this->assertSame([['ok', 'messenger', 'sent on and handled']], array_map(fn ($r) => [$r->status, $r->trigger, $r->output], $runs));
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

    public function testTheBundlesOwnScheduleRunsTheCheck(): void
    {
        self::bootKernel();
        $cw = $this->client();
        $cw->job('seen', ['schedule' => '@hourly']);
        $provider = static::getContainer()->get('Cronwatch\Symfony\CheckSchedule');
        $messages = $provider->getSchedule()->getRecurringMessages();
        $this->assertCount(1, $messages);
        $this->assertSame('every 5 minutes', (string) $messages[0]->getTrigger());
        $handled = static::getContainer()->get(MessageBusInterface::class)->dispatch(new CheckMessage());
        $result = $handled->last(\Symfony\Component\Messenger\Stamp\HandledStamp::class)->getResult();
        $this->assertSame('cronwatch: checked 1 job, sent 0 alerts', $result->summary());
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
