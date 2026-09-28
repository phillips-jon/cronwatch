<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Symfony\Component\Scheduler\RecurringMessage;
use Symfony\Component\Scheduler\Schedule;
use Symfony\Component\Scheduler\ScheduleProviderInterface;

/**
 * The bundle's own schedule, "cronwatch": a CheckMessage every five minutes
 * (check.frequency). Consume it alongside the app's own:
 *
 *     bin/console messenger:consume scheduler_default scheduler_cronwatch
 *
 * @internal
 */
final class CheckSchedule implements ScheduleProviderInterface
{
    private ?Schedule $schedule = null;

    public function __construct(private readonly string $frequency = '5 minutes')
    {
    }

    public function getSchedule(): Schedule
    {
        return $this->schedule ??= (new Schedule())->add(
            preg_match('/^\S+\s+\S+\s+\S+\s+\S+\s+\S+/', $this->frequency) === 1
                ? RecurringMessage::cron($this->frequency, new CheckMessage())
                : RecurringMessage::every($this->frequency, new CheckMessage()),
        );
    }
}
