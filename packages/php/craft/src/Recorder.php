<?php

declare(strict_types=1);

namespace Cronwatch\Craft;

use Cronwatch\Alert;
use Cronwatch\Alerts\Slack;
use Cronwatch\Alerts\Webhook;
use Cronwatch\Bridge\JobName;
use Cronwatch\Bridge\Unscheduled;
use Cronwatch\CheckResult;
use Cronwatch\Craft\models\Settings;
use Cronwatch\Cronwatch;
use Cronwatch\Duration;
use Cronwatch\Job\JobHandle;
use Cronwatch\Watch;
use Craft;
use craft\helpers\UrlHelper;
use yii\base\ActionEvent;
use yii\base\Event;
use yii\queue\ExecEvent;

/**
 * CronWatch in a Craft site: the client, the jobs, and the runs.
 *
 * - Queue jobs that opt in (#[Cronwatch\Watch] on the class, or listed in
 *   the settings' queueJobs) are recorded as the queue runs them (`craft
 *   queue/run`, `queue/listen`, or the queue runner a Control Panel request
 *   starts), each attempt a run: Queue::EVENT_BEFORE_EXEC starts it,
 *   EVENT_AFTER_EXEC ends it ok, EVENT_AFTER_ERROR ends it failed, so
 *   failing attempts open one alert and the one that succeeds closes it.
 * - Console commands the host's crontab runs are watched when the settings'
 *   commands list their route (with a schedule), or their controller has
 *   the WatchCommand behavior: the controller's EVENT_BEFORE_ACTION starts
 *   the run, EVENT_AFTER_ACTION ends it (failed for a non-zero exit code),
 *   and an exception, which ends the command before EVENT_AFTER_ACTION, is
 *   recorded from the console error handler.
 *
 * Craft has no scheduler of its own, so a schedule is what the settings (or
 * the behavior, or #[Watch]) say the crontab does.
 */
final class Recorder
{
    public const TRIGGER_QUEUE = 'queue';
    public const TRIGGER_COMMAND = 'command';
    public const TAG_QUEUE = 'craft-queue';
    public const TAG_COMMAND = 'craft-command';
    /** Jobs declared from the settings, which the check declares again without a schedule once they are taken out. */
    public const TAG_CONFIG = 'craft-config';

    private ?Cronwatch $client = null;
    /** @var array<string, int> queue job id => the attempt's run key */
    private array $queueRuns = [];
    /** @var list<array{string, int}> the open command runs, innermost last: [route, key] */
    private array $commandRuns = [];

    public function __construct(private readonly Plugin $plugin)
    {
    }

    public function settings(): Settings
    {
        $settings = $this->plugin->getSettings();
        return $settings instanceof Settings ? $settings : new Settings();
    }

    public function client(): Cronwatch
    {
        if ($this->client !== null) {
            return $this->client;
        }
        $channels = $this->channels();
        $grace = $this->settings()->value('grace');
        try {
            Duration::parse($grace, 'grace');
        } catch (\Throwable) {
            $grace = '10m';
        }
        return $this->client = new Cronwatch(
            store: Storage::store(),
            alerts: $channels === [] ? [new LogChannel()] : $channels,
            defaults: ['grace' => $grace],
            onError: $this->report(...),
        );
    }

    /** Forgets the client, so the next call reads the settings again. */
    public function reset(): void
    {
        $this->client = null;
    }

    public function report(\Throwable $error, string $where): void
    {
        Craft::error("{$where}: " . get_class($error) . ': ' . $error->getMessage(), 'cronwatch');
    }

    /**
     * The channels the settings name, and any added by a Plugin::EVENT_ALERTS
     * listener. With none, alerts go to Craft's log.
     *
     * @return list<mixed>
     */
    public function channels(): array
    {
        $settings = $this->settings();
        $link = fn (Alert $alert): string => $this->jobUrl($alert->job);
        $channels = [];
        $email = $settings->value('emailTo');
        if ($email !== '') {
            $site = (string) (Craft::$app->getSystemName() ?? '');
            $channels[] = new MailChannel($email, $site !== '' ? "[{$site}]" : null, $link);
        }
        $slack = $settings->value('slackWebhookUrl');
        if ($slack !== '') {
            $channels[] = new Slack($slack, $link);
        }
        $webhook = $settings->value('webhookUrl');
        if ($webhook !== '') {
            $secret = $settings->value('webhookSecret');
            $channels[] = new Webhook($webhook, [], $secret !== '' ? $secret : null);
        }
        $event = new AlertsEvent(['channels' => $channels]);
        Event::trigger(Plugin::class, Plugin::EVENT_ALERTS, $event);
        return array_values($event->channels);
    }

    /** The dashboard's page for a job, for alert links. */
    public function jobUrl(string $job): string
    {
        try {
            return UrlHelper::cpUrl('cronwatch', ['job' => $job]);
        } catch (\Throwable) {
            return '';
        }
    }

    // ------------------------------------------------------------ the jobs

    /**
     * The options an entry of the settings' commands or queueJobs gives: its
     * array, or none for true; null when it is false.
     *
     * @return array<string, mixed>|null
     */
    private static function entry(mixed $value): ?array
    {
        return match (true) {
            is_array($value) => $value,
            $value === true => [],
            default => null,
        };
    }

    /**
     * This install's tag under an integration's tag, from Craft's application
     * id (CRAFT_APP_ID, made at install), so two installs sharing one store
     * and prefix never declare each other's jobs without a schedule (see
     * Unscheduled).
     */
    public static function appTag(string $tag): string
    {
        $id = (string) (Craft::$app->id ?? '');
        return Unscheduled::appTag($tag, $id !== '' ? $id : 'craft');
    }

    /**
     * Declares a job: the name from the options' "name" when there is one,
     * the tags added to, and the definition the client keeps.
     *
     * @param array<string, mixed> $options
     * @param list<string> $tags
     */
    private function declare(string $name, array $options, array $tags): JobHandle
    {
        $given = $options['name'] ?? null;
        unset($options['name']);
        if (in_array(self::TAG_CONFIG, $tags, true)) {
            $tags[] = self::appTag(self::TAG_CONFIG);
        }
        $options['tags'] = array_values(array_unique([...array_map('strval', (array) ($options['tags'] ?? [])), ...$tags]));
        return $this->client()->job(is_string($given) && $given !== '' ? $given : $name, $options);
    }

    /** A console route's job name: "craft:resave:entries" for resave/entries. */
    public static function commandName(string $route): string
    {
        return JobName::clean('craft:' . str_replace('/', ':', trim($route, '/')));
    }

    /**
     * The job a queue job runs as, or null when its class is not watched.
     *
     * @return array{string, array<string, mixed>, list<string>}|null the name, options and tags
     */
    public function queueJob(string $class): ?array
    {
        $listed = self::entry($this->settings()->queueJobs[$class] ?? null);
        if ($listed !== null) {
            return [JobName::ofClass($class), $listed + ['description' => "Queue job {$class}"], [self::TAG_QUEUE, self::TAG_CONFIG]];
        }
        $watch = Watch::of($class);
        if ($watch === null || !$watch->enabled) {
            return null;
        }
        $options = $watch->options() + ['description' => "Queue job {$class}"];
        if ($watch->name !== null) {
            $options['name'] = $watch->name;
        }
        return [JobName::ofClass($class), $options, [self::TAG_QUEUE]];
    }

    /**
     * The job a console action runs as, or null when it is not watched: the
     * settings' entry for its route, else its controller's WatchCommand.
     *
     * @return array{string, array<string, mixed>, list<string>}|null
     */
    public function commandJob(object $controller, string $route, string $actionId): ?array
    {
        if ($route === 'cronwatch/check') {
            return null;
        }
        $listed = self::entry($this->settings()->commands[$route] ?? null);
        if ($listed !== null) {
            return [self::commandName($route), $listed + ['description' => "craft {$route}"], [self::TAG_COMMAND, self::TAG_CONFIG]];
        }
        if (method_exists($controller, 'getBehaviors')) {
            foreach ($controller->getBehaviors() as $behavior) {
                if ($behavior instanceof WatchCommand && $behavior->watches($actionId)) {
                    return [self::commandName($route), $behavior->options() + ['description' => "craft {$route}"], [self::TAG_COMMAND]];
                }
            }
        }
        return null;
    }

    /**
     * What a check starts with: the settings' commands and queue jobs
     * declared, and jobs the settings no longer list declared again without
     * their schedule, so they are never reported missed.
     */
    public function prepare(): Cronwatch
    {
        $cw = $this->client();
        $settings = $this->settings();
        foreach ($settings->commands as $route => $value) {
            $options = self::entry($value);
            if ($options !== null && $route !== 'cronwatch/check') {
                $this->safely(fn () => $this->declare(self::commandName((string) $route), $options + ['description' => "craft {$route}"], [self::TAG_COMMAND, self::TAG_CONFIG]), "declaring {$route}");
            }
        }
        foreach ($settings->queueJobs as $class => $value) {
            $options = self::entry($value);
            if ($options !== null) {
                $this->safely(fn () => $this->declare(JobName::ofClass((string) $class), $options + ['description' => "Queue job {$class}"], [self::TAG_QUEUE, self::TAG_CONFIG]), "declaring {$class}");
            }
        }
        Unscheduled::declare($cw, self::TAG_CONFIG, self::appTag(self::TAG_CONFIG), $this->report(...));
        return $cw;
    }

    public function check(): CheckResult
    {
        return $this->prepare()->check();
    }

    // ------------------------------------------------------------ queue jobs

    /** Queue::EVENT_BEFORE_EXEC: a watched job's attempt starts. */
    public function jobStarting(ExecEvent $event): void
    {
        $job = $event->job;
        if (!is_object($job) || $event->id === null) {
            return;
        }
        $found = $this->queueJob($job::class);
        if ($found === null) {
            return;
        }
        $this->safely(function () use ($event, $found): void {
            [$name, $options, $tags] = $found;
            $handle = $this->declare($name, $options, $tags);
            $id = (string) $event->id;
            $runId = strlen($id) <= 100 ? "craft-queue:{$id}:{$event->attempt}:" . bin2hex(random_bytes(4)) : null;
            $this->queueRuns[$id] = $this->client()->startExecution($handle->definition, self::TRIGGER_QUEUE, $runId);
        }, 'starting ' . $job::class);
    }

    /** Queue::EVENT_AFTER_EXEC: the attempt succeeded. */
    public function jobFinished(ExecEvent $event): void
    {
        $this->endJob($event, null, $event->result);
    }

    /** Queue::EVENT_AFTER_ERROR: the attempt failed (the queue retries it or gives up). */
    public function jobFailed(ExecEvent $event): void
    {
        $this->endJob($event, $event->error ?? 'The job failed', null);
    }

    private function endJob(ExecEvent $event, mixed $error, mixed $result): void
    {
        $id = (string) $event->id;
        $key = $this->queueRuns[$id] ?? null;
        if ($key === null) {
            return;
        }
        unset($this->queueRuns[$id]);
        $this->safely(fn () => $this->client()->finishExecution($key, is_string($result) ? $result : null, $error, $error !== null), 'finishing a queue job');
    }

    // ------------------------------------------------------------ commands

    /** A console controller's EVENT_BEFORE_ACTION. */
    public function commandStarting(ActionEvent $event): void
    {
        if (!$event->isValid) {
            return;
        }
        $action = $event->action;
        $route = $action->getUniqueId();
        $found = $this->commandJob($action->controller, $route, $action->id);
        if ($found === null) {
            return;
        }
        $this->safely(function () use ($found, $route): void {
            [$name, $options, $tags] = $found;
            $handle = $this->declare($name, $options, $tags);
            $this->commandRuns[] = [$route, $this->client()->startExecution($handle->definition, self::TRIGGER_COMMAND)];
        }, "starting {$route}");
    }

    /** A console controller's EVENT_AFTER_ACTION: the exit code decides. */
    public function commandFinished(ActionEvent $event): void
    {
        $route = $event->action->getUniqueId();
        $open = end($this->commandRuns);
        if ($open === false || $open[0] !== $route) {
            return;
        }
        array_pop($this->commandRuns);
        $code = is_int($event->result) ? $event->result : 0;
        $this->safely(fn () => $code === 0
            ? $this->client()->finishExecution($open[1], is_string($event->result) ? $event->result : null)
            : $this->client()->finishExecution($open[1], null, "Exited with code {$code}", true), "finishing {$route}");
    }

    /** The console error handler: a command that threw ends with the exception. */
    public function commandFailed(\Throwable $error): void
    {
        while (($open = array_pop($this->commandRuns)) !== null) {
            $this->safely(fn () => $this->client()->finishExecution($open[1], null, $error, true), "finishing {$open[0]}");
        }
    }

    /** Runs `fn`, reporting what it throws: the command or job goes on whatever CronWatch does. */
    private function safely(callable $fn, string $where): void
    {
        try {
            $fn();
        } catch (\Throwable $error) {
            try {
                $this->report($error, $where);
            } catch (\Throwable) {
            }
        }
    }
}
