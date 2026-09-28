<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Cronwatch\Bridge\JobName;
use Cronwatch\Bridge\Unscheduled;
use Cronwatch\Cronwatch;
use Cronwatch\Job\JobHandle;
use Cronwatch\Watch;
use Symfony\Component\Messenger\Envelope;
use Symfony\Component\Scheduler\Generator\MessageContext;
use Symfony\Component\Scheduler\RecurringMessage;
use Symfony\Component\Scheduler\ScheduleProviderInterface;
use Symfony\Component\Scheduler\Trigger\CronExpressionTrigger;
use Symfony\Component\Scheduler\Trigger\JitterTrigger;
use Symfony\Component\Scheduler\Trigger\PeriodicalTrigger;
use Symfony\Component\Scheduler\Trigger\TriggerInterface;

/**
 * The app's schedules (every #[AsSchedule] provider, #[AsCronTask] and
 * #[AsPeriodicTask] included) as CronWatch jobs, each recurring message
 * one job with its trigger as the schedule, declared on the client so a
 * check knows every message, including one that never ran.
 *
 * A job is named after its message, unless #[Cronwatch\Watch(name: ...)]
 * on the message's class or the bundle's `scheduler.jobs` names it:
 *
 * - a message object after its class, backslashes as dots
 *   (App.Message.SendReport);
 * - a command (#[AsCronTask] on a command, RunCommandMessage) after the
 *   command as written, as Laravel's are (`app:prune --days=30` is
 *   `app:prune-days-30-<8 hex>`);
 * - a service method (#[AsCronTask] on a service, ServiceCallMessage) after
 *   the service's id and the method, unless it is __invoke;
 * - a message sent on to a transport (RedispatchMessage) after the message
 *   it carries. When that message's class is watched through Messenger
 *   (#[Cronwatch\Watch]), its runs are the handler's, recorded where it is
 *   handled, and the schedule only declares the schedule.
 *
 * A schedule other than "default" puts its name in front: `reports:App.Message.Build`.
 * A CronExpressionTrigger gives its expression and zone (a hashed "#" one
 * as resolved), a PeriodicalTrigger `every <seconds>s`, and a JitterTrigger
 * its inner trigger's; a trigger that does not fire at fixed times
 * (ExcludeTimeTrigger, CallbackTrigger, a calendar interval such as "1
 * month") leaves the job without a schedule, reported once. Two messages
 * with one name on different schedules are one job without a schedule.
 *
 * @internal
 */
final class ScheduledMessages
{
    public const TAG = 'symfony-scheduler';

    /** @var array<string, string> "<schedule>\0<recurring message id>" => job name */
    private array $names = [];
    /** @var array<string, array{options: array<string, mixed>, defer: bool, schedules: list<string>}> */
    private array $jobs = [];
    /** @var array<string, JobHandle> */
    private array $handles = [];
    /** @var array<class-string, string> a message class sent on to Messenger => the job it runs as */
    private array $redispatched = [];
    /** @var array<string, true> the recurring messages that are a RedispatchMessage */
    private array $sentOn = [];
    private bool $planned = false;
    /** @var array<string, true> every schedule, by name */
    private array $schedules = [];
    /** @var array<string, true> the schedules that send the check (CheckMessage) */
    private array $checkIn = [];
    /** @var array<string, true> */
    private array $reported = [];

    /**
     * @param \Closure(): Cronwatch $client
     * @param iterable<string, ScheduleProviderInterface> $providers every schedule, by name
     * @param array<string, mixed> $config the bundle's scheduler settings
     * @param string|null $app this app's name in its jobs' tags (the bundle's app_id), or null (see appTag())
     * @param object|null $parameters the container's parameter bag, to read kernel.secret from
     */
    public function __construct(
        private readonly \Closure $client,
        private readonly iterable $providers,
        private readonly array $config = [],
        private readonly bool $messenger = true,
        private ?string $app = null,
        private readonly ?object $parameters = null,
        private readonly string $projectDir = '',
    ) {
    }

    /**
     * This app's tag under the scheduler's ("symfony-scheduler:<app>"), so
     * two apps sharing a store never take each other's jobs for their own.
     * The bundle's `app_id` names the app; without one it is "app-" and 12
     * hex characters of a hash of the kernel's secret (APP_SECRET), which
     * stays the same across deploys and differs between apps, else of the
     * project directory (see DESIGN.md).
     */
    public function appTag(): string
    {
        if ($this->app === null) {
            $secret = null;
            try {
                if ($this->parameters !== null && method_exists($this->parameters, 'has') && $this->parameters->has('kernel.secret')) {
                    $secret = $this->parameters->get('kernel.secret');
                }
            } catch (\Throwable) {
                // An APP_SECRET that is not set: the project directory instead.
            }
            $this->app = 'app-' . substr(hash('sha256', is_string($secret) && $secret !== '' ? "cronwatch:secret:{$secret}" : "cronwatch:dir:{$this->projectDir}"), 0, 12);
        }
        return Unscheduled::appTag(self::TAG, $this->app);
    }

    private function cw(): Cronwatch
    {
        return ($this->client)();
    }

    /** @return list<string> every schedule's jobs, declared */
    public function declare(): array
    {
        if (!$this->planned) {
            $this->plan();
        }
        $cw = $this->cw();
        foreach ($this->jobs as $name => $job) {
            $this->declareOne($cw, $name);
        }
        return array_keys($this->handles);
    }

    /**
     * For `cronwatch:check --status`: every schedule with the number of its
     * messages watched as jobs, and the schedules that send the check.
     *
     * @return array{schedules: array<string, int>, check: list<string>}
     */
    public function status(): array
    {
        if (!$this->planned) {
            $this->plan();
        }
        $schedules = array_map(fn () => 0, $this->schedules);
        foreach (array_keys($this->names) as $key) {
            $schedule = explode("\0", (string) $key, 2)[0];
            $schedules[$schedule] = ($schedules[$schedule] ?? 0) + 1;
        }
        ksort($schedules);
        $check = array_map('strval', array_keys($this->checkIn));
        sort($check);
        return ['schedules' => $schedules, 'check' => $check];
    }

    /** What a check starts with: every message declared, and jobs of messages no longer scheduled declared without their schedule. */
    public function prepare(): Cronwatch
    {
        $this->declare();
        $cw = $this->cw();
        Unscheduled::declare($cw, self::TAG, $this->appTag(), fn (\Throwable $e, string $where) => $cw->onError($e, $where));
        return $cw;
    }

    /**
     * The job a scheduled message runs as, declared, or null when it is not
     * watched; `recorded` is false for a message Messenger's watcher records.
     *
     * @return array{JobHandle, bool}|null
     */
    public function handleFor(string $schedule, MessageContext $context, object $message): ?array
    {
        if (!$this->planned) {
            $this->plan();
        }
        $key = $schedule . "\0" . $context->id;
        if (isset($this->sentOn[$key]) && self::carried($message) === $message) {
            // The message a RedispatchMessage carried, handled where it was sent (newer
            // Symfony dispatches the Scheduler's events there too): the Messenger watcher's.
            return null;
        }
        if (!isset($this->names[$key])) {
            // A message the plan did not see (a schedule built afresh on each call, say): planned on its own.
            $this->add($schedule, $context->id, $context->trigger, $message);
            $this->settle();
        }
        $name = $this->names[$key] ?? null;
        if ($name === null || !isset($this->jobs[$name])) {
            return null;
        }
        $handle = $this->declareOne($this->cw(), $name);
        return $handle === null ? null : [$handle, !$this->jobs[$name]['defer']];
    }

    /**
     * The job a message class Messenger's watcher records runs as, with its
     * schedule's options, when a schedule sends it on; null otherwise.
     *
     * @return array{string, array<string, mixed>}|null
     */
    public function redispatchedJob(string $class): ?array
    {
        if (!$this->planned) {
            try {
                $this->plan();
            } catch (\Throwable) {
                return null;
            }
        }
        $name = $this->redispatched[$class] ?? null;
        return $name !== null && isset($this->jobs[$name]) ? [$name, $this->jobs[$name]['options']] : null;
    }

    private function declareOne(Cronwatch $cw, string $name): ?JobHandle
    {
        $options = $this->jobs[$name]['options'];
        $current = $this->handles[$name] ?? null;
        if ($current !== null) {
            foreach ($cw->definedJobs() as $definition) {
                if ($definition === $current->definition) {
                    return $current;
                }
            }
        }
        try {
            return $this->handles[$name] = $cw->job($name, $options);
        } catch (\Throwable $error) {
            $this->reportOnce($error, "declaring {$name}");
        }
        unset($options['schedule'], $options['timezone']);
        try {
            return $this->handles[$name] = $cw->job($name, $options);
        } catch (\Throwable $error) {
            $this->reportOnce($error, "declaring {$name}");
            unset($this->handles[$name]);
            return null;
        }
    }

    private function plan(): void
    {
        $this->planned = true;
        $this->names = $this->jobs = $this->handles = $this->redispatched = $this->sentOn = $this->checkIn = $this->schedules = [];
        // The default schedule first, then the rest as the container lists them.
        $providers = [];
        foreach ($this->providers as $schedule => $provider) {
            $providers[(string) $schedule] = $provider;
        }
        if (isset($providers['default'])) {
            $providers = ['default' => $providers['default']] + $providers;
        }
        foreach ($providers as $schedule => $provider) {
            $this->schedules[(string) $schedule] = true;
            try {
                foreach ($provider->getSchedule()->getRecurringMessages() as $recurring) {
                    $this->addRecurring((string) $schedule, $recurring);
                }
            } catch (\Throwable $error) {
                $this->reportOnce($error, "reading the {$schedule} schedule");
            }
        }
        $this->settle();
    }

    private function addRecurring(string $schedule, RecurringMessage $recurring): void
    {
        $trigger = $recurring->getTrigger();
        $context = new MessageContext($schedule, $recurring->getId(), $trigger, new \DateTimeImmutable());
        foreach ($recurring->getMessages($context) as $message) {
            if (is_object($message)) {
                $this->add($schedule, $recurring->getId(), $trigger, $message);
            }
        }
    }

    private function add(string $schedule, string $id, TriggerInterface $trigger, object $message): void
    {
        if ($message instanceof CheckMessage) {
            $this->checkIn[$schedule] = true;
            return;
        }
        $carried = self::carried($message);
        $watch = Watch::of($carried);
        if ($watch !== null && !$watch->enabled) {
            return;
        }
        [$name, $description] = self::describe($message);
        if ($watch?->name !== null && $watch->name !== '') {
            $name = $watch->name;
        } elseif ($schedule !== 'default') {
            $name = JobName::clean("{$schedule}:{$name}");
        }
        $defer = $carried !== $message && $this->messenger && $watch !== null;
        $given = $this->config['jobs'][$name] ?? null;
        if ($given === false || in_array($name, (array) ($this->config['exclude'] ?? []), true)) {
            return;
        }
        $given = is_array($given) ? $given : [];
        $name = is_string($given['name'] ?? null) && $given['name'] !== '' ? $given['name'] : $name;
        unset($given['name']);
        $options = [];
        $timing = $this->timing($name, $trigger);
        if ($timing !== null) {
            $options += $timing;
        }
        $options['description'] = $description;
        foreach ([...($watch?->options() ?? []), ...$given] as $key => $value) {
            $options[(string) $key] = $value;
        }
        $options['tags'] = array_values(array_unique([...array_map('strval', (array) ($options['tags'] ?? [])), self::TAG, $this->appTag()]));
        $options = array_filter($options, fn ($value) => $value !== null);
        $this->names[$schedule . "\0" . $id] = $name;
        if ($carried !== $message) {
            $this->sentOn[$schedule . "\0" . $id] = true;
        }
        if (!isset($this->jobs[$name])) {
            $this->jobs[$name] = ['options' => $options, 'defer' => $defer, 'schedules' => []];
        }
        $this->jobs[$name]['schedules'][] = isset($options['schedule']) ? $options['schedule'] . ' ' . ($options['timezone'] ?? '') : '';
        if ($defer) {
            $this->redispatched[$carried::class] = $name;
        }
    }

    private function settle(): void
    {
        foreach ($this->jobs as $name => $job) {
            if (count(array_unique($job['schedules'])) > 1) {
                unset($this->jobs[$name]['options']['schedule'], $this->jobs[$name]['options']['timezone']);
                $this->reportOnce(new \RuntimeException(count($job['schedules']) . " scheduled messages are named {$name}, on different schedules, so the job is watched without a schedule; give each its own name with #[Cronwatch\\Watch(name: ...)] or cronwatch.scheduler.jobs"), "declaring {$name}");
            }
        }
    }

    /** The message a RedispatchMessage carries, or the message itself. */
    public static function carried(object $message): object
    {
        if (is_a($message, 'Symfony\Component\Messenger\Message\RedispatchMessage')) {
            $inner = $message->envelope;
            return $inner instanceof Envelope ? $inner->getMessage() : $inner;
        }
        return $message;
    }

    /**
     * The default job name and description of a message.
     *
     * @return array{string, string}
     */
    public static function describe(object $message): array
    {
        $message = self::carried($message);
        if (is_a($message, 'Symfony\Component\Console\Messenger\RunCommandMessage')) {
            return [JobName::clean($message->input), $message->input];
        }
        if (is_a($message, 'Symfony\Component\Scheduler\Messenger\ServiceCallMessage')) {
            $method = $message->getMethod();
            $label = $message->getServiceId() . ($method === '__invoke' ? '' : "::{$method}");
            return [JobName::ofClass($message->getServiceId()) . ($method === '__invoke' ? '' : '.' . JobName::clean($method)), $label];
        }
        return [JobName::ofClass($message::class), $message::class];
    }

    /**
     * A trigger's schedule, or null (reported once) for one that does not fire at fixed times.
     *
     * @return array{schedule: string, timezone?: string}|null
     */
    private function timing(string $name, TriggerInterface $trigger): ?array
    {
        try {
            $timing = self::scheduleOf($trigger);
        } catch (\Throwable) {
            $timing = null;
        }
        if ($timing === null) {
            $this->reportOnce(new \RuntimeException("the trigger \"{$trigger}\" does not fire at fixed times, so the job is watched without a schedule; give it one in cronwatch.scheduler.jobs"), "declaring {$name}");
        }
        return $timing;
    }

    /** @return array{schedule: string, timezone?: string}|null */
    public static function scheduleOf(TriggerInterface $trigger): ?array
    {
        while ($trigger instanceof JitterTrigger) {
            $trigger = $trigger->inner();
        }
        if ($trigger instanceof CronExpressionTrigger) {
            $zone = (fn () => $this->timezone ?? null)->call($trigger);
            return ['schedule' => (string) $trigger, 'timezone' => is_string($zone) && $zone !== '' ? $zone : date_default_timezone_get()];
        }
        if ($trigger instanceof PeriodicalTrigger) {
            $seconds = (int) (fn () => $this->intervalInSeconds ?? 0)->call($trigger);
            return $seconds > 0 ? ['schedule' => 'every ' . \Cronwatch\Duration::interval($seconds)] : null;
        }
        return null;
    }

    private function reportOnce(\Throwable $error, string $where): void
    {
        $key = $where . "\n" . $error->getMessage();
        if (isset($this->reported[$key])) {
            return;
        }
        $this->reported[$key] = true;
        $this->cw()->onError($error, $where);
    }
}
