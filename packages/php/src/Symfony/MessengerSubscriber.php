<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Cronwatch\Bridge\JobName;
use Cronwatch\Cronwatch;
use Cronwatch\Job\JobHandle;
use Cronwatch\Watch;
use Symfony\Component\EventDispatcher\EventSubscriberInterface;
use Symfony\Component\Messenger\Event\WorkerMessageFailedEvent;
use Symfony\Component\Messenger\Event\WorkerMessageHandledEvent;
use Symfony\Component\Messenger\Event\WorkerMessageReceivedEvent;
use Symfony\Component\Messenger\Exception\HandlerFailedException;
use Symfony\Component\Messenger\Stamp\HandledStamp;
use Symfony\Component\Messenger\Stamp\TransportMessageIdStamp;

/**
 * Messages whose class carries #[Cronwatch\Watch], recorded where a worker
 * handles them (messenger:consume), so queued work is the run rather than
 * its dispatch: WorkerMessageReceivedEvent starts the run (trigger
 * "symfony-messenger", "messenger" before 1.0; the handler's
 * Cronwatch::current() is its context),
 * WorkerMessageHandledEvent ends it ok with the handler's result, and
 * WorkerMessageFailedEvent ends it failed with what the handler threw.
 * Every attempt is a run of its own, so a retried message's failing
 * attempts open one failed alert and the attempt that succeeds closes it,
 * as the gem's Sidekiq and the Python package's Celery count them. A
 * message a schedule sends straight to its handler is the Scheduler
 * watcher's; a message handled synchronously (no transport) never reaches
 * a worker and is not a run.
 *
 * @internal
 */
final class MessengerSubscriber implements EventSubscriberInterface
{
    public const TRIGGER = 'symfony-messenger';
    public const TAG = 'symfony-messenger';

    /** @var array<int, int> spl_object_id(message) => the run's execution key */
    private array $open = [];
    /** @var array<class-string, array{Cronwatch, JobHandle}> */
    private array $handles = [];

    /** @param \Closure(): Cronwatch $client */
    public function __construct(private readonly \Closure $client, private readonly ?ScheduledMessages $scheduled = null)
    {
    }

    public static function getSubscribedEvents(): array
    {
        return [
            WorkerMessageReceivedEvent::class => ['received', -1024],
            WorkerMessageHandledEvent::class => 'handled',
            WorkerMessageFailedEvent::class => 'failed',
        ];
    }

    public function received(WorkerMessageReceivedEvent $event): void
    {
        $envelope = $event->getEnvelope();
        $message = $envelope->getMessage();
        // A schedule's own transport (scheduler_<name>) is the Scheduler watcher's. A message a
        // schedule sent on keeps its ScheduledStamp, and is this watcher's where it is handled.
        if (str_starts_with($event->getReceiverName(), 'scheduler_') || (method_exists($event, 'shouldHandle') && !$event->shouldHandle())) {
            return;
        }
        $watch = Watch::of($message);
        if ($watch === null || !$watch->enabled) {
            return;
        }
        $handle = $this->handle($message::class, $watch);
        if ($handle === null) {
            return;
        }
        $transportId = $envelope->last(TransportMessageIdStamp::class)?->getId();
        $id = is_scalar($transportId) && (string) $transportId !== '' && strlen((string) $transportId) <= 150
            ? "{$event->getReceiverName()}:{$transportId}:" . bin2hex(random_bytes(6))
            : null;
        $this->open[spl_object_id($message)] = ($this->client)()->startExecution($handle->definition, self::TRIGGER, $id !== null && strlen($id) <= 200 ? $id : null);
    }

    public function handled(WorkerMessageHandledEvent $event): void
    {
        $key = $this->take($event->getEnvelope()->getMessage());
        if ($key !== null) {
            ($this->client)()->finishExecution($key, $event->getEnvelope()->last(HandledStamp::class)?->getResult());
        }
    }

    public function failed(WorkerMessageFailedEvent $event): void
    {
        $key = $this->take($event->getEnvelope()->getMessage());
        if ($key !== null) {
            ($this->client)()->finishExecution($key, null, self::unwrap($event->getThrowable()), true);
        }
    }

    /** What a handler threw, out of Messenger's HandlerFailedException. */
    public static function unwrap(\Throwable $error): \Throwable
    {
        if ($error instanceof HandlerFailedException) {
            $wrapped = method_exists($error, 'getWrappedExceptions') ? $error->getWrappedExceptions() : [];
            $first = reset($wrapped);
            if ($first instanceof \Throwable) {
                return $first;
            }
            return $error->getPrevious() ?? $error;
        }
        return $error;
    }

    private function take(object $message): ?int
    {
        $id = spl_object_id($message);
        $key = $this->open[$id] ?? null;
        unset($this->open[$id]);
        return $key;
    }

    private function handle(string $class, Watch $watch): ?JobHandle
    {
        $cw = ($this->client)();
        [$client, $handle] = $this->handles[$class] ?? [null, null];
        if ($client === $cw && $handle !== null) {
            return $handle;
        }
        try {
            // A message a schedule sends on (RedispatchMessage) is declared with its schedule, as the check declares it.
            $scheduled = $this->scheduled?->redispatchedJob($class);
            [$name, $options] = $scheduled ?? self::definition($class, $watch);
            $handle = $cw->job($name, $options);
        } catch (\Throwable $error) {
            $cw->onError($error, "declaring {$class}");
            return null;
        }
        $this->handles[$class] = [$cw, $handle];
        return $handle;
    }

    /** @return array{string, array<string, mixed>} */
    public static function definition(string $class, Watch $watch): array
    {
        $options = $watch->options() + ['description' => "Message {$class}"];
        $options['tags'] = array_values(array_unique([...array_map('strval', (array) ($options['tags'] ?? [])), self::TAG]));
        return [$watch->name !== null && $watch->name !== '' ? $watch->name : JobName::ofClass($class), $options];
    }
}
