<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Cronwatch\Cronwatch;
use Symfony\Component\EventDispatcher\EventSubscriberInterface;
use Symfony\Component\Messenger\Event\WorkerMessageHandledEvent;
use Symfony\Component\Messenger\Stamp\HandledStamp;
use Symfony\Component\Scheduler\Event\FailureEvent;
use Symfony\Component\Scheduler\Event\PostRunEvent;
use Symfony\Component\Scheduler\Event\PreRunEvent;

/**
 * Records each scheduled message's handling as a run, from the Scheduler's
 * events in the worker that consumes the schedule (messenger:consume
 * scheduler_<name>), so every recurring message is watched with no code
 * changes: PreRunEvent starts the run (trigger "scheduler"; the handler's
 * Cronwatch::current() is its context), PostRunEvent ends it ok with the
 * handler's result (a string is the output, an HTTP response of 400 or more
 * fails it), and FailureEvent ends it failed with what the handler threw.
 * A message another PreRunEvent listener cancels is left as a run that
 * ended ok with nothing done, as Symfony handled it.
 *
 * @internal
 */
final class SchedulerSubscriber implements EventSubscriberInterface
{
    public const TRIGGER = 'symfony-scheduler';

    /** @var array<int, int> spl_object_id(message) => the run's execution key */
    private array $open = [];
    /** @var array<int, mixed> spl_object_id(message) => what its handler returned */
    private array $results = [];

    /** @param \Closure(): Cronwatch $client */
    public function __construct(private readonly \Closure $client, private readonly ScheduledMessages $messages)
    {
    }

    public static function getSubscribedEvents(): array
    {
        return [
            // After other listeners, so one that cancels the run has done so.
            PreRunEvent::class => ['preRun', -1024],
            PostRunEvent::class => 'postRun',
            FailureEvent::class => 'failure',
            // Before the Scheduler turns it into PostRunEvent, whose getResult() Symfony 6.4 lacks.
            WorkerMessageHandledEvent::class => ['handled', 16],
        ];
    }

    /** The handler's result, kept for postRun() on Symfony 6.4. */
    public function handled(WorkerMessageHandledEvent $event): void
    {
        $message = $event->getEnvelope()->getMessage();
        if (isset($this->open[spl_object_id($message)])) {
            $this->results[spl_object_id($message)] = $event->getEnvelope()->last(HandledStamp::class)?->getResult();
        }
    }

    public function preRun(PreRunEvent $event): void
    {
        if ($event->shouldCancel()) {
            return;
        }
        $context = $event->getMessageContext();
        $found = $this->messages->handleFor($context->name, $context, $event->getMessage());
        if ($found === null || !$found[1]) {
            return;
        }
        $this->open[spl_object_id($event->getMessage())] = ($this->client)()->startExecution($found[0]->definition, self::TRIGGER);
    }

    public function postRun(PostRunEvent $event): void
    {
        $id = spl_object_id($event->getMessage());
        $result = method_exists($event, 'getResult') ? $event->getResult() : ($this->results[$id] ?? null);
        unset($this->results[$id]);
        $key = $this->take($event->getMessage());
        if ($key !== null) {
            ($this->client)()->finishExecution($key, $result);
        }
    }

    public function failure(FailureEvent $event): void
    {
        $key = $this->take($event->getMessage());
        if ($key !== null) {
            ($this->client)()->finishExecution($key, null, MessengerSubscriber::unwrap($event->getError()), true);
        }
    }

    private function take(object $message): ?int
    {
        $id = spl_object_id($message);
        $key = $this->open[$id] ?? null;
        unset($this->open[$id]);
        return $key;
    }
}
