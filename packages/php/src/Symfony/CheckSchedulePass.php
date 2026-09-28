<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Symfony\Component\DependencyInjection\Compiler\CompilerPassInterface;
use Symfony\Component\DependencyInjection\ContainerBuilder;
use Symfony\Component\DependencyInjection\Reference;

/**
 * Puts the check in the schedule `check.schedule` names: CheckSchedule
 * decorates the app's provider for that schedule when it has one, and is
 * the schedule's provider otherwise. It runs before the Scheduler's own pass
 * (AddScheduleMessengerPass), which then adds the #[AsCronTask] and
 * #[AsPeriodicTask] tasks of that schedule on top and makes its transport.
 *
 * @internal
 */
final class CheckSchedulePass implements CompilerPassInterface
{
    public const TAG = 'cronwatch.check_schedule';

    public function process(ContainerBuilder $container): void
    {
        if (!$container->hasDefinition(CheckSchedule::class)) {
            return;
        }
        $definition = $container->getDefinition(CheckSchedule::class);
        $name = (string) ($definition->getTag(self::TAG)[0]['schedule'] ?? 'default');
        $definition->clearTag(self::TAG);
        foreach ($container->findTaggedServiceIds('scheduler.schedule_provider') as $id => $tags) {
            if ($id !== CheckSchedule::class && ($tags[0]['name'] ?? null) === $name) {
                $definition->setDecoratedService($id)->setArgument(1, new Reference(CheckSchedule::class . '.inner'));
                return;
            }
        }
        $definition->addTag('scheduler.schedule_provider', ['name' => $name]);
    }
}
