<?php

declare(strict_types=1);

namespace Cronwatch\Laravel;

use Cronwatch\Cronwatch;
use Cronwatch\Env;
use Cronwatch\Laravel\Http\Authorize;
use Cronwatch\Laravel\Http\DashboardController;
use Illuminate\Console\Events\CommandStarting;
use Illuminate\Console\Events\ScheduledBackgroundTaskFinished;
use Illuminate\Console\Events\ScheduledTaskFailed;
use Illuminate\Console\Events\ScheduledTaskFinished;
use Illuminate\Console\Events\ScheduledTaskStarting;
use Illuminate\Console\Scheduling\Event as ScheduledEvent;
use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Contracts\Auth\Access\Gate;
use Illuminate\Contracts\Events\Dispatcher;
use Illuminate\Queue\Events\JobExceptionOccurred;
use Illuminate\Queue\Events\JobFailed;
use Illuminate\Queue\Events\JobProcessed;
use Illuminate\Queue\Events\JobProcessing;
use Illuminate\Queue\Events\JobTimedOut;
use Illuminate\Support\ServiceProvider;

/**
 * CronWatch in a Laravel app, found by package discovery: the client as a
 * singleton (Cronwatch\Cronwatch) made from config/cronwatch.php, every
 * scheduled task watched through the scheduler's events, queued jobs that
 * opt in watched through the queue's, `cronwatch:check` scheduled every five
 * minutes, the dashboard at /cronwatch behind the viewCronwatch gate, and
 * the tables' migration. See DESIGN.md for how tasks become jobs.
 */
final class CronwatchServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->mergeConfigFrom(__DIR__ . '/config/cronwatch.php', 'cronwatch');
        $this->app->singleton(ClientFactory::class, fn ($app) => new ClientFactory($app));
        $this->app->singleton(Cronwatch::class, fn ($app) => $app->make(ClientFactory::class)->client());
        $this->app->singleton(QueueWatcher::class, fn ($app) => new QueueWatcher($app));
        $this->app->singleton(ScheduledTasks::class, fn ($app) => new ScheduledTasks($app, $app->make(QueueWatcher::class)));
        $this->app->singleton(ScheduleWatcher::class, fn ($app) => new ScheduleWatcher($app, $app->make(ScheduledTasks::class)));
    }

    public function boot(): void
    {
        $app = $this->app;
        // The environment when no variable names one: the app's own.
        Env::setFallback(fn () => $app->environment());

        $this->publishes([__DIR__ . '/config/cronwatch.php' => $this->app->configPath('cronwatch.php')], 'cronwatch-config');
        $migrations = [__DIR__ . '/migrations' => $this->app->databasePath('migrations')];
        if (method_exists($this, 'publishesMigrations')) {
            $this->publishesMigrations($migrations, 'cronwatch-migrations');
        } else {
            $this->publishes($migrations, 'cronwatch-migrations');
        }
        $config = $this->app->make('config');
        if ($config->get('cronwatch.store.migrations', true) && $config->get('cronwatch.store.driver', 'database') === 'database') {
            $this->loadMigrationsFrom(__DIR__ . '/migrations');
        }
        if ($this->app->runningInConsole()) {
            $this->commands([CheckCommand::class]);
        }

        ScheduledEvent::macro('cronwatch', function (array|false $options = []) {
            /** @var ScheduledEvent $this */
            EventOptions::set($this, $options);
            return $this;
        });

        if (!$config->get('cronwatch.enabled', true)) {
            return;
        }
        $events = $this->app->make(Dispatcher::class);
        if ($config->get('cronwatch.schedule.watch', true)) {
            $events->listen(ScheduledTaskStarting::class, fn ($event) => $app->make(ScheduleWatcher::class)->starting($event));
            $events->listen(ScheduledTaskFinished::class, fn ($event) => $app->make(ScheduleWatcher::class)->finished($event));
            $events->listen(ScheduledTaskFailed::class, fn ($event) => $app->make(ScheduleWatcher::class)->failed($event));
            $events->listen(ScheduledBackgroundTaskFinished::class, fn ($event) => $app->make(ScheduleWatcher::class)->backgroundFinished($event));
            // The schedule's jobs are declared as schedule:run starts, so the
            // first task's run finds every name already worked out.
            $events->listen(CommandStarting::class, function (CommandStarting $event) use ($app): void {
                if (in_array($event->command, ['schedule:run', 'schedule:finish'], true)) {
                    try {
                        $app->make(ScheduledTasks::class)->declare();
                    } catch (\Throwable $error) {
                        $app->make(Cronwatch::class)->onError($error, 'declaring the schedule');
                    }
                }
            });
        }
        if (Settings::scheduleCheck($config)) {
            $this->callAfterResolving(Schedule::class, function (Schedule $schedule) use ($config): void {
                $schedule->command(ScheduledTasks::CHECK_COMMAND)->cron(Settings::checkFrequency($config));
            });
        }
        if ($config->get('cronwatch.queue.watch', true)) {
            $events->listen(JobProcessing::class, fn ($event) => $app->make(QueueWatcher::class)->processing($event));
            $events->listen(JobProcessed::class, fn ($event) => $app->make(QueueWatcher::class)->processed($event));
            $events->listen(JobExceptionOccurred::class, fn ($event) => $app->make(QueueWatcher::class)->failed($event));
            $events->listen(JobFailed::class, fn ($event) => $app->make(QueueWatcher::class)->failed($event));
            if (class_exists(JobTimedOut::class)) {
                $events->listen(JobTimedOut::class, fn ($event) => $app->make(QueueWatcher::class)->timedOut($event));
            }
        }
        if ($config->get('cronwatch.dashboard.enabled', true)) {
            $this->dashboard();
        }
    }

    private function dashboard(): void
    {
        $gate = $this->app->make(Gate::class);
        if (!$gate->has(Authorize::GATE)) {
            $app = $this->app;
            $gate->define(Authorize::GATE, fn ($user = null): bool => $app->environment('local'));
        }
        if ($this->app->routesAreCached()) {
            return;
        }
        $config = $this->app->make('config');
        $path = trim((string) $config->get('cronwatch.dashboard.path', 'cronwatch'), '/');
        $router = $this->app->make('router');
        $group = ['prefix' => $path, 'middleware' => (array) $config->get('cronwatch.dashboard.middleware', ['web', Authorize::class])];
        $domain = $config->get('cronwatch.dashboard.domain');
        if (is_string($domain) && $domain !== '') {
            $group['domain'] = $domain;
        }
        $router->group($group, function ($router): void {
            // The routes refuse cross-site writes themselves (the SDK's same-origin rule), and their forms carry no Laravel token.
            $csrf = array_values(array_filter(
                ['Illuminate\Foundation\Http\Middleware\PreventRequestForgery', 'Illuminate\Foundation\Http\Middleware\ValidateCsrfToken', 'Illuminate\Foundation\Http\Middleware\VerifyCsrfToken'],
                'class_exists',
            ));
            $router->any('{path?}', DashboardController::class)
                ->where('path', '.*')
                ->withoutMiddleware($csrf)
                ->name('cronwatch.dashboard');
        });
    }
}
