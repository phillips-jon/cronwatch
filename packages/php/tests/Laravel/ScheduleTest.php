<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Laravel;

use Cronwatch\Cronwatch;
use Cronwatch\Laravel\ScheduledTasks;
use Cronwatch\Tests\Laravel\Fixtures\InvokableTask;
use Cronwatch\Tests\Laravel\Fixtures\PlainQueuedJob;
use Cronwatch\Tests\Laravel\Fixtures\WatchedQueuedJob;
use Illuminate\Console\Scheduling\Schedule;
use Orchestra\Testbench\Attributes\DefineEnvironment;

/**
 * The scheduler: how each kind of scheduled task becomes a job, and its
 * runs recorded from the scheduler's events as `schedule:run` runs them.
 */
final class ScheduleTest extends TestCase
{
    private function schedule(): Schedule
    {
        return $this->app->make(Schedule::class);
    }

    /** @return array<string, array<string, mixed>> the declared jobs' definitions, by name */
    private function declared(Cronwatch $cw): array
    {
        $this->app->make(ScheduledTasks::class)->declare();
        $out = [];
        foreach ($cw->definedJobs() as $definition) {
            $out[(string) $definition->get('name')] = $definition->fields;
        }
        return $out;
    }

    public function testEveryKindOfTaskIsAJobNamedAsDesignMdSays(): void
    {
        $cw = $this->client();
        $schedule = $this->schedule();
        $schedule->command('emails:send')->dailyAt('02:00');
        $schedule->command('emails:send --force')->hourly()->timezone('America/New_York');
        $schedule->exec('node /home/forge/script.js')->everyFiveMinutes();
        $schedule->call(fn () => null)->name('prune-tokens')->daily();
        $line = __LINE__ + 1;
        $schedule->call(fn () => null)->weekly();
        $schedule->call([InvokableTask::class, 'handle'])->monthly();
        $schedule->call(new InvokableTask())->everyTenMinutes();
        $schedule->job(new PlainQueuedJob())->everyFifteenMinutes();
        $schedule->job(new WatchedQueuedJob())->everyThirtyMinutes();

        $jobs = $this->declared($cw);
        $closure = "closure:ScheduleTest.php:{$line}";
        $this->assertSame([
            'emails:send', 'emails:send-force-' . substr(md5('emails:send --force'), 0, 8),
            'node-home-forge-script.js-' . substr(md5('node /home/forge/script.js'), 0, 8),
            'prune-tokens', $closure, 'Cronwatch.Tests.Laravel.Fixtures.InvokableTask.handle', 'Cronwatch.Tests.Laravel.Fixtures.InvokableTask',
            'Cronwatch.Tests.Laravel.Fixtures.PlainQueuedJob', 'nightly-report',
        ], array_keys($jobs));
        $this->assertSame(['schedule' => '0 2 * * *', 'timezone' => 'UTC', 'description' => 'emails:send', 'tags' => ['laravel-scheduler', 'laravel-scheduler:laravel'], 'name' => 'emails:send'], $jobs['emails:send']);
        $this->assertSame('America/New_York', $jobs['emails:send-force-' . substr(md5('emails:send --force'), 0, 8)]['timezone']);
        $this->assertSame('*/5 * * * *', $jobs['node-home-forge-script.js-' . substr(md5('node /home/forge/script.js'), 0, 8)]['schedule']);
        $this->assertStringStartsWith('A closure in ScheduleTest.php at line', $jobs[$closure]['description']);
        // The watched queued job's schedule is declared under its own name, with its own options too.
        $this->assertSame('*/30 * * * *', $jobs['nightly-report']['schedule']);
        $this->assertSame('15m', $jobs['nightly-report']['grace']);
        $this->assertSame(['nightly', 'laravel-queue', 'laravel-scheduler', 'laravel-scheduler:laravel'], $jobs['nightly-report']['tags']);
        $this->assertSame([], $this->errors);
    }

    public function testCronwatchOptionsFiltersEnvironmentsCollisionsAndTheCheckItself(): void
    {
        $cw = $this->client();
        $schedule = $this->schedule();
        $schedule->command('reports:build')->hourly()->cronwatch(['name' => 'reports', 'grace' => '5m', 'tags' => ['team-a']]);
        $schedule->command('left:out')->hourly()->cronwatch(false);
        $schedule->command('office:hours')->hourly()->between('9:00', '17:00');
        $schedule->command('office:given')->hourly()->when(fn () => true)->cronwatch(['schedule' => '0 9-17 * * *']);
        $schedule->command('prod:only')->hourly()->environments(['production']);
        $schedule->command('twice')->dailyAt('01:00');
        $schedule->command('twice')->dailyAt('13:00');
        $schedule->command('same')->dailyAt('01:00');
        $schedule->command('same')->dailyAt('01:00');
        $schedule->command('bad:zone')->hourly()->timezone('Mars/Olympus');

        $jobs = $this->declared($cw);
        $this->assertArrayHasKey('reports', $jobs);
        $this->assertSame(['schedule' => '0 * * * *', 'timezone' => 'UTC', 'description' => 'reports:build', 'grace' => '5m', 'tags' => ['team-a', 'laravel-scheduler', 'laravel-scheduler:laravel'], 'name' => 'reports'], $jobs['reports']);
        $this->assertArrayNotHasKey('left:out', $jobs);
        $this->assertArrayNotHasKey('schedule', $jobs['office:hours'], 'a filtered task has no schedule to miss');
        $this->assertSame('0 9-17 * * *', $jobs['office:given']['schedule']);
        $this->assertArrayNotHasKey('prod:only', $jobs, 'not in this environment');
        $this->assertArrayNotHasKey('schedule', $jobs['twice']);
        $this->assertSame('0 1 * * *', $jobs['same']['schedule']);
        $this->assertArrayNotHasKey('schedule', $jobs['bad:zone']);
        $this->assertArrayNotHasKey('cronwatch:check', $jobs, 'the check is not a job');
        $this->assertTrue(collect($schedule->events())->contains(fn ($e) => str_contains((string) $e->command, 'cronwatch:check') && $e->expression === '*/5 * * * *'), 'the provider schedules the check');
        $this->assertSame(['declaring twice', 'declaring bad:zone'], $this->wheres());
        $this->assertStringContainsString('2 scheduled tasks are named twice, on different schedules', $this->messages()[0]);
        $this->app->make(ScheduledTasks::class)->declare();
        $this->assertCount(2, $this->errors, 'reported once');
    }

    public function testScheduleRunRecordsCallbacksAndShellCommands(): void
    {
        $cw = $this->client();
        $this->app['config']->set('cronwatch.schedule.capture_output', true);
        $schedule = $this->schedule();
        $schedule->call(function () {
            Cronwatch::current()->log('pruned 3 tokens');
            Cronwatch::current()->metric('pruned', 3);
        })->everyMinute()->name('prune');
        $schedule->call(fn () => 'returned text')->everyMinute()->name('returns');
        $schedule->call(fn () => throw new \RuntimeException('database is down'))->everyMinute()->name('throws');
        $schedule->call(fn () => false)->everyMinute()->name('false');
        $schedule->exec('echo hello from the shell')->everyMinute()->cronwatch(['name' => 'shell']);
        $schedule->exec("sh -c 'echo about to fail; exit 3'")->everyMinute()->cronwatch(['name' => 'exits']);

        $this->artisan('schedule:run')->assertExitCode(0);

        $run = fn (string $name) => $cw->runs($name)[0] ?? null;
        $this->assertSame(['ok', 'pruned 3 tokens', ['pruned' => 3], 'laravel-scheduler'], [$run('prune')->status, $run('prune')->output, $run('prune')->metrics, $run('prune')->trigger]);
        $this->assertSame(['ok', 'returned text'], [$run('returns')->status, $run('returns')->output]);
        $this->assertSame('failed', $run('throws')->status);
        $this->assertStringStartsWith("RuntimeException: database is down\n    at ", $run('throws')->error);
        $this->assertSame(['failed', 'Returned false'], [$run('false')->status, $run('false')->error]);
        $this->assertSame(['ok', 'hello from the shell'], [$run('shell')->status, $run('shell')->output]);
        $this->assertSame(['failed', 'Exited with code 3', 'about to fail'], [$run('exits')->status, $run('exits')->error, $run('exits')->output]);
        $this->assertNull(Cronwatch::current(), 'nothing is left current');
        $this->assertSame(['failed', 'failed', 'failed'], $this->capture->types());
        foreach ($schedule->events() as $event) {
            $this->assertSame($event->getDefaultOutput(), $event->output, 'the output setting is put back');
        }
    }

    public function testACommandSendingItsOutputNowhereRecordsNoneUnlessCaptureIsOn(): void
    {
        $cw = $this->client();
        $event = $this->schedule()->exec('echo discarded')->everyMinute()->cronwatch(['name' => 'discards']);
        $this->artisan('schedule:run')->assertExitCode(0);
        $run = $cw->runs('discards')[0];
        $this->assertSame(['ok', null], [$run->status, $run->output], 'the output went where the task sent it');
        $this->assertSame($event->getDefaultOutput(), $event->output);
    }

    public function testOutputFilesLeftByRunsThatNeverEndedAreSwept(): void
    {
        $cw = $this->client();
        $this->app['config']->set('cronwatch.schedule.capture_output', true);
        $stale = [(string) tempnam(sys_get_temp_dir(), 'cronwatch-schedule-'), storage_path('framework/schedule-cronwatch-' . sha1('killed') . '.log')];
        $fresh = [(string) tempnam(sys_get_temp_dir(), 'cronwatch-schedule-'), storage_path('framework/schedule-cronwatch-' . sha1('running') . '.log')];
        foreach ([...$stale, ...$fresh] as $file) {
            file_put_contents($file, 'left behind');
        }
        foreach ($stale as $file) {
            touch($file, time() - 2 * 86400);
        }
        try {
            $this->schedule()->exec('echo captured')->everyMinute()->cronwatch(['name' => 'captures']);
            $this->artisan('schedule:run')->assertExitCode(0);
            $this->assertSame('captured', $cw->runs('captures')[0]->output);
            foreach ($stale as $file) {
                $this->assertFileDoesNotExist($file);
            }
            foreach ($fresh as $file) {
                $this->assertFileExists($file, 'a file under a day old may be a run still going');
            }
        } finally {
            array_map(fn (string $file) => @unlink($file), [...$stale, ...$fresh]);
        }
    }

    public function testATaskOutputFileIsReadFromWhereTheRunStarted(): void
    {
        $cw = $this->client();
        $dir = sys_get_temp_dir() . '/cw-laravel-' . bin2hex(random_bytes(4));
        mkdir($dir);
        file_put_contents("{$dir}/append.log", "an earlier run\n");
        try {
            $schedule = $this->schedule();
            $schedule->exec('echo this run')->everyMinute()->appendOutputTo("{$dir}/append.log")->cronwatch(['name' => 'appends']);
            $schedule->exec('echo only this')->everyMinute()->sendOutputTo("{$dir}/send.log")->cronwatch(['name' => 'sends']);
            $this->artisan('schedule:run')->assertExitCode(0);
            $this->assertSame('this run', $cw->runs('appends')[0]->output);
            $this->assertSame('only this', $cw->runs('sends')[0]->output);
            $this->assertSame("an earlier run\nthis run\n", file_get_contents("{$dir}/append.log"), 'the file is the task\'s, untouched');
        } finally {
            array_map('unlink', glob("{$dir}/*") ?: []);
            rmdir($dir);
        }
    }

    public function testSkippedAndOverlappingTasksRecordNothing(): void
    {
        $cw = $this->client();
        $schedule = $this->schedule();
        $schedule->call(fn () => null)->everyMinute()->name('never')->when(fn () => false);
        $locked = $schedule->call(fn () => null)->everyMinute()->name('locked')->withoutOverlapping();
        $locked->mutex->create($locked);
        try {
            $this->artisan('schedule:run')->assertExitCode(0);
        } finally {
            $locked->mutex->forget($locked);
        }
        $this->assertSame([], $cw->runs('never'));
        $this->assertSame([], $cw->runs('locked'));
        $this->artisan('schedule:run')->assertExitCode(0);
        $this->assertCount(1, $cw->runs('locked'), 'once the lock is gone it runs');
        $this->assertSame('* * * * *', $cw->store->getJob('locked')->definition->get('schedule'), 'withoutOverlapping() is not a filter: the task keeps its schedule');
    }

    public function testATaskLaravelSkipsForOverlappingAfterItStartedLeavesNoRun(): void
    {
        // The lock taken between the watcher's look and Laravel's (Laravel 13 says so).
        $cw = $this->client();
        $event = $this->schedule()->call(fn () => null)->hourly()->name('raced')->withoutOverlapping();
        if (!property_exists($event, 'skippedBecauseOverlapping')) {
            $this->markTestSkipped('this Laravel does not say when it skipped a task for overlapping');
        }
        $watcher = $this->app->make(\Cronwatch\Laravel\ScheduleWatcher::class);
        $this->artisan('cronwatch:check')->assertExitCode(0);
        $this->clock->advance(3 * 3600_000);
        $this->artisan('cronwatch:check')->assertExitCode(0);
        $this->assertSame(['missed'], $this->capture->types());
        $watcher->starting(new \Illuminate\Console\Events\ScheduledTaskStarting($event));
        $this->assertSame(['running'], array_map(fn ($r) => $r->status, $cw->runs('raced')));
        $event->skippedBecauseOverlapping = true;
        $watcher->finished(new \Illuminate\Console\Events\ScheduledTaskFinished($event, 0.1));
        $this->assertSame([], $cw->runs('raced'));
        $this->clock->advance(60_000);
        $this->artisan('cronwatch:check')->assertExitCode(0);
        $this->assertSame(['missed'], $this->capture->types(), 'missed stays open, alerted once');
        $this->assertSame([], $this->errors);
    }

    public function testABackgroundTaskIsFinishedByScheduleFinish(): void
    {
        $cw = $this->client();
        $this->app['config']->set('cronwatch.schedule.capture_output', true);
        $event = $this->schedule()->exec("sh -c 'echo in the background; exit 2'")->everyMinute()->runInBackground()->cronwatch(['name' => 'background']);
        $this->artisan('schedule:run')->assertExitCode(0);
        $this->assertSame('running', $cw->runs('background')[0]->status);
        // The command line Laravel ran ends by calling schedule:finish in a process of its own;
        // the test's app is not one that process can boot, so it is called here once the output is there.
        $file = storage_path('framework/schedule-cronwatch-' . sha1($event->mutexName()) . '.log');
        for ($i = 0; $i < 100 && !str_contains((string) @file_get_contents($file), 'background'); $i++) {
            usleep(20_000);
        }
        $this->artisan('schedule:finish', ['id' => $event->mutexName(), 'code' => 2])->assertExitCode(0);
        $run = $cw->runs('background')[0];
        $this->assertSame(['failed', 'Exited with code 2', 'in the background'], [$run->status, $run->error, $run->output]);
        $this->assertFileDoesNotExist($file);
    }

    public function testABackgroundRunStartedBefore10UnderTheOldTriggerIsStillFinished(): void
    {
        $cw = $this->client();
        $event = $this->schedule()->exec('backup')->daily()->runInBackground()->cronwatch(['name' => 'backup']);
        [$handle] = $this->app->make(ScheduledTasks::class)->handleFor($event);
        // A run 0.x started, with the trigger it wrote then; the upgrade happens while it runs.
        $handle->start(trigger: 'schedule');
        file_put_contents(storage_path('framework/schedule-cronwatch-' . sha1($event->mutexName()) . '.log'), 'backed up');
        $this->artisan('schedule:finish', ['id' => $event->mutexName(), 'code' => 0])->assertExitCode(0);
        $run = $cw->runs('backup')[0];
        $this->assertSame(['ok', 'schedule', 'backed up'], [$run->status, $run->trigger, $run->output]);

        $this->assertSame([], $this->errors);
    }

    public function testABackgroundTaskThatRanPastItsTimeoutIsStillFinished(): void
    {
        $cw = $this->client();
        $event = $this->schedule()->exec('backup')->daily()->runInBackground()->withoutOverlapping()->cronwatch(['name' => 'backup', 'timeout' => '1h']);
        $watcher = $this->app->make(\Cronwatch\Laravel\ScheduleWatcher::class);
        $file = storage_path('framework/schedule-cronwatch-' . sha1($event->mutexName()) . '.log');
        $starting = function () use ($watcher, $event): void {
            $watcher->starting(new \Illuminate\Console\Events\ScheduledTaskStarting($event));
            $event->output = $event->getDefaultOutput();
        };
        $finish = function (int $code, string $output) use ($event, $file): void {
            file_put_contents($file, $output);
            $this->artisan('schedule:finish', ['id' => $event->mutexName(), 'code' => $code])->assertExitCode(0);
        };
        $statuses = fn () => array_map(fn ($r) => $r->status, $cw->runs('backup'));

        // A run past its timeout, marked by a check, then ending 30 minutes later.
        $starting();
        $this->clock->advance(90 * 60_000);
        $this->artisan('cronwatch:check')->assertExitCode(0);
        $this->assertSame(['timeout'], $statuses());
        $this->assertSame(['stuck'], $this->capture->types());
        $finish(1, 'disk full');
        $run = $cw->runs('backup')[0];
        $this->assertSame(['failed', 'Exited with code 1', 'disk full'], [$run->status, $run->error, $run->output]);

        // One that died, marked timeout and never finished, is not given a later run's finish.
        $this->clock->advance(60_000);
        $starting();
        $this->clock->advance(90 * 60_000);
        $this->artisan('cronwatch:check')->assertExitCode(0);
        $this->clock->advance(60_000);
        $starting();
        $finish(0, 'backed up');
        $this->assertSame(['ok', 'timeout', 'failed'], $statuses());
        $this->assertSame('backed up', $cw->runs('backup')[0]->output);
        $this->assertSame([], $this->errors);
    }

    public function testAScheduledQueuedJobIsRecordedByTheQueueNotTheScheduler(): void
    {
        $cw = $this->client();
        $this->app['config']->set('queue.default', 'sync');
        $this->schedule()->job(new WatchedQueuedJob())->everyMinute();
        $this->schedule()->job(new PlainQueuedJob())->everyMinute();
        $this->artisan('schedule:run')->assertExitCode(0);
        $runs = $cw->runs('nightly-report');
        $this->assertCount(1, $runs);
        $this->assertSame(['laravel-queue', 'ok', 'Report written'], [$runs[0]->trigger, $runs[0]->status, $runs[0]->output]);
        $plain = $cw->runs('Cronwatch.Tests.Laravel.Fixtures.PlainQueuedJob');
        $this->assertSame([['laravel-scheduler', 'ok']], array_map(fn ($r) => [$r->trigger, $r->status], $plain), 'the dispatch is the run of a job the queue does not watch');
    }

    public function testTheCheckDeclaresEveryTaskReportsOneThatNeverRanAndUnschedulesOnesTakenOut(): void
    {
        $cw = $this->client();
        $this->schedule()->command('reports:build')->hourly();
        $this->artisan('cronwatch:check')->expectsOutput('cronwatch: checked 1 job, sent 0 alerts')->assertExitCode(0);
        $this->clock->advance(2 * 3600_000);
        $this->artisan('cronwatch:check')->expectsOutput('cronwatch: checked 1 job, sent 1 alert')->assertExitCode(0);
        $this->assertSame(['missed'], $this->capture->types());

        // The task is taken out of the schedule: its job is declared again without one, and missed recovers.
        $store = $cw->store;
        $this->refreshApplication();
        $cw = $this->client(['store' => $store]);
        $this->artisan('cronwatch:check')->expectsOutput('cronwatch: checked 1 job, sent 1 alert')->assertExitCode(0);
        $this->assertSame(['recovered'], $this->capture->types());
        $definition = $cw->store->getJob('reports:build')->definition;
        $this->assertFalse($definition->has('schedule'));
        $this->assertSame('reports:build (no longer scheduled)', $definition->get('description'));
    }

    public function testTwoAppsSharingAStoreNeverUnscheduleEachOthersJobs(): void
    {
        $store = new \Cronwatch\Store\MemoryStore();
        $check = function (string $app, ?string $command) use ($store): void {
            $this->refreshApplication();
            $this->app['config']->set('app.name', $app);
            $this->client(['store' => $store]);
            if ($command !== null) {
                $this->schedule()->command($command)->hourly();
            }
            $this->artisan('cronwatch:check')->assertExitCode(0);
        };
        $check('Shop', 'shop:sync');
        $this->assertSame(['laravel-scheduler', 'laravel-scheduler:shop'], $store->getJob('shop:sync')->definition->get('tags'));
        $check('Blog', 'blog:publish');
        $this->assertTrue($store->getJob('shop:sync')->definition->has('schedule'), 'the blog leaves the shop\'s job alone');
        $this->assertSame(['laravel-scheduler', 'laravel-scheduler:blog'], $store->getJob('blog:publish')->definition->get('tags'));
        $check('Shop', 'shop:sync');
        $this->assertTrue($store->getJob('blog:publish')->definition->has('schedule'), 'and the shop the blog\'s');
        $check('Blog', null);
        $this->assertFalse($store->getJob('blog:publish')->definition->has('schedule'), 'the blog\'s own task taken out');
        $this->assertTrue($store->getJob('shop:sync')->definition->has('schedule'));
        $check('Shop', null);
        $this->assertFalse($store->getJob('shop:sync')->definition->has('schedule'));
        $this->assertSame([], $this->errors);
    }

    public function testTheAppIdNamesTheAppOverItsName(): void
    {
        $this->app['config']->set('cronwatch.app_id', 'Billing API');
        $cw = $this->client();
        $this->schedule()->command('invoices:send')->daily();
        $this->artisan('cronwatch:check')->assertExitCode(0);
        $this->assertSame(['laravel-scheduler', 'laravel-scheduler:billing-api'], $cw->store->getJob('invoices:send')->definition->get('tags'));
    }

    public function testACheckThatFailsExitsOne(): void
    {
        $store = new \Cronwatch\Tests\Support\DelegatingStore(new \Cronwatch\Store\MemoryStore());
        $store->broken = ['init' => true];
        $this->client(['store' => $store]);
        $this->artisan('cronwatch:check')->doesntExpectOutput('cronwatch: checked 0 jobs, sent 0 alerts')->assertExitCode(1);
    }

    protected function checkOff($app): void
    {
        $app['config']->set('cronwatch.check.schedule', false);
    }

    protected function checkEveryTen($app): void
    {
        $app['config']->set('cronwatch.check.frequency', '*/10 * * * *');
    }

    protected function turnedOff($app): void
    {
        $app['config']->set('cronwatch.enabled', false);
    }

    #[DefineEnvironment('checkOff')]
    public function testTheCheckIsNotScheduledWhenTurnedOff(): void
    {
        $this->assertFalse(collect($this->schedule()->events())->contains(fn ($e) => str_contains((string) $e->command, 'cronwatch:check')));
    }

    #[DefineEnvironment('checkEveryTen')]
    public function testTheCheckRunsAsOftenAsConfigured(): void
    {
        $this->assertTrue(collect($this->schedule()->events())->contains(fn ($e) => str_contains((string) $e->command, 'cronwatch:check') && $e->expression === '*/10 * * * *'));
    }

    #[DefineEnvironment('turnedOff')]
    public function testNothingIsWatchedWhenTurnedOff(): void
    {
        $cw = $this->client();
        $this->schedule()->call(fn () => null)->everyMinute()->name('quiet');
        $this->artisan('schedule:run')->assertExitCode(0);
        $this->assertSame([], $cw->runs('quiet'));
        $this->assertFalse(collect($this->schedule()->events())->contains(fn ($e) => str_contains((string) $e->command, 'cronwatch:check')));
    }
}
