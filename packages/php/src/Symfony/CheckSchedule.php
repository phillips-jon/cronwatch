<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Symfony\Component\Scheduler\Generator\MessageContext;
use Symfony\Component\Scheduler\RecurringMessage;
use Symfony\Component\Scheduler\Schedule;
use Symfony\Component\Scheduler\ScheduleProviderInterface;

/**
 * The check in a schedule: a CheckMessage every five minutes
 * (check.frequency, a period or a cron expression), added to the schedule
 * `check.schedule` names, "default" unless told otherwise, so the worker
 * that already runs the app's scheduled messages runs the check too:
 *
 *     bin/console messenger:consume scheduler_default
 *
 * When the app has a provider for that schedule (#[AsSchedule], or the one
 * #[AsCronTask] and #[AsPeriodicTask] make) this decorates it and adds the
 * check to its Schedule once; otherwise this is the schedule's provider.
 *
 * @internal
 */
final class CheckSchedule implements ScheduleProviderInterface
{
    /** @var \WeakMap<Schedule, true> the schedules the check was added to */
    private \WeakMap $added;
    private ?Schedule $own = null;

    public function __construct(private readonly string $frequency = '5 minutes', private readonly ?ScheduleProviderInterface $inner = null)
    {
        $this->added = new \WeakMap();
    }

    public function getSchedule(): Schedule
    {
        $schedule = $this->inner !== null ? $this->inner->getSchedule() : ($this->own ??= new Schedule());
        if (!isset($this->added[$schedule])) {
            $this->added[$schedule] = true;
            if (!self::sendsCheck($schedule)) {
                $schedule->add($this->message());
            }
        }
        return $schedule;
    }

    /** Whether the app's schedule already sends the check itself (RecurringMessage::every(..., new CheckMessage())). */
    private static function sendsCheck(Schedule $schedule): bool
    {
        foreach ($schedule->getRecurringMessages() as $recurring) {
            try {
                $context = new MessageContext('cronwatch', $recurring->getId(), $recurring->getTrigger(), new \DateTimeImmutable());
                foreach ($recurring->getMessages($context) as $message) {
                    if ($message instanceof CheckMessage) {
                        return true;
                    }
                }
            } catch (\Throwable) {
                // A message provider that cannot say without running: not the check.
            }
        }
        return false;
    }

    public function message(): RecurringMessage
    {
        return preg_match('/^\S+\s+\S+\s+\S+\s+\S+\s+\S+/', $this->frequency) === 1
            ? RecurringMessage::cron($this->frequency, new CheckMessage())
            : RecurringMessage::every($this->frequency, new CheckMessage());
    }
}
