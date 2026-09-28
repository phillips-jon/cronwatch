<?php

// CronWatch for Laravel. Publish with
// `php artisan vendor:publish --tag=cronwatch-config`. Every value reads the
// environment, so most apps need only a few lines in .env.

return [

    // Off: nothing is watched, no check is scheduled and the dashboard is
    // not mounted. The client (app(Cronwatch\Cronwatch::class)) still works.
    'enabled' => env('CRONWATCH_ENABLED', true),

    // This app's name in its scheduled jobs' tags (laravel-scheduler:<name>),
    // default app.name. Two apps sharing one store and table prefix need
    // different names, or each would take the other's jobs for its own tasks
    // taken out of the schedule.
    'app_id' => env('CRONWATCH_APP_ID'),

    // Where jobs, runs and state are kept.
    //   database  the app's database (MySQL, MariaDB, Postgres or SQLite), through
    //             a connection of CronWatch's own made from that connection's
    //             settings, so its writes never join the app's transactions
    //   sqlite    a SQLite file of its own (path)
    //   memory    forgets when the process ends; for tests
    'store' => [
        'driver' => env('CRONWATCH_STORE', 'database'),
        'connection' => env('CRONWATCH_DB_CONNECTION'),
        'path' => env('CRONWATCH_SQLITE_PATH'),
        'prefix' => env('CRONWATCH_TABLE_PREFIX', 'cronwatch_'),
        // `php artisan migrate` makes the tables (the migration is loaded from
        // the package; publish it with --tag=cronwatch-migrations to keep a copy).
        'migrations' => env('CRONWATCH_MIGRATIONS', true),
        // Whether each process may run CREATE TABLE IF NOT EXISTS itself. Turn it
        // off when the migration made the tables and the app's database user may
        // not create tables.
        'create_tables' => env('CRONWATCH_CREATE_TABLES', true),
    ],

    // Where alerts go. With none set, alerts are written to the log.
    'alerts' => [
        // Through the app's mailer.
        'mail' => [
            'to' => env('CRONWATCH_MAIL_TO'),
            'from' => env('CRONWATCH_MAIL_FROM'),
            'mailer' => env('CRONWATCH_MAILER'),
            'subject_prefix' => env('CRONWATCH_MAIL_SUBJECT_PREFIX'),
        ],
        'slack' => env('CRONWATCH_SLACK_WEBHOOK_URL'),
        'discord' => env('CRONWATCH_DISCORD_WEBHOOK_URL'),
        'webhook' => [
            'url' => env('CRONWATCH_WEBHOOK_URL'),
            'secret' => env('CRONWATCH_WEBHOOK_SECRET'),
        ],
        // A log channel from config/logging.php, written to as well as the
        // channels above (with none above, alerts go to the default channel).
        'log' => env('CRONWATCH_LOG_CHANNEL'),
        // More channels: classes implementing Cronwatch\Alerts\AlertChannel,
        // made by the container.
        'channels' => [],
    ],

    // Claude triage: a short diagnosis added to each alert. Reads ANTHROPIC_API_KEY.
    'triage' => [
        'enabled' => env('CRONWATCH_TRIAGE', false),
        'model' => env('CRONWATCH_TRIAGE_MODEL'),
        'context' => env('CRONWATCH_TRIAGE_CONTEXT'),
    ],

    // The secret a job's handler() and the dashboard's /api/check take.
    'cron_secret' => env('CRON_SECRET'),
    'retention' => env('CRONWATCH_RETENTION', '30d'),
    // grace, timeout, timezone and failuresBeforeAlert for every job that sets none.
    'defaults' => [],
    // "check" queues alerts for the check to send, for processes that cannot reach the network.
    'deliver' => env('CRONWATCH_DELIVER', 'now'),

    // The scheduler: every task in routes/console.php (or withSchedule())
    // is a job, recorded as it runs, with no code changes. Options per task
    // with ->cronwatch([...]), or ->cronwatch(false) to leave one out.
    'schedule' => [
        'watch' => env('CRONWATCH_WATCH_SCHEDULE', true),
        // Job names left out.
        'exclude' => [],
        // Schedule `cronwatch:check` in the app's own scheduler.
        'check' => env('CRONWATCH_SCHEDULE_CHECK', true),
        'check_cron' => env('CRONWATCH_CHECK_CRON', '*/5 * * * *'),
    ],

    // Queued jobs marked #[Cronwatch\Watch] or implementing
    // Cronwatch\Laravel\ShouldBeWatched: each attempt is a run.
    'queue' => [
        'watch' => env('CRONWATCH_WATCH_QUEUE', true),
    ],

    // The dashboard and JSON API.
    'dashboard' => [
        'enabled' => env('CRONWATCH_DASHBOARD', true),
        'path' => env('CRONWATCH_PATH', 'cronwatch'),
        'domain' => env('CRONWATCH_DOMAIN'),
        // Who may see it: the viewCronwatch gate (by default, anyone in the
        // local environment only; define it in a service provider to widen it).
        'middleware' => ['web', Cronwatch\Laravel\Http\Authorize::class],
        // A request with a bearer token (@cronwatch/mcp, a platform cron calling
        // /api/check with CRON_SECRET) skips the gate and must carry this token
        // instead. Default: CRONWATCH_TOKEN.
        'token' => env('CRONWATCH_TOKEN'),
    ],

];
