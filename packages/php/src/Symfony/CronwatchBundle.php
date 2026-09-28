<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Cronwatch\Cronwatch;
use Cronwatch\Env;
use Symfony\Component\Config\Definition\Configurator\DefinitionConfigurator;
use Symfony\Component\DependencyInjection\ContainerBuilder;
use Symfony\Component\DependencyInjection\Loader\Configurator\ContainerConfigurator;
use Symfony\Component\HttpKernel\Bundle\AbstractBundle;

use function Symfony\Component\DependencyInjection\Loader\Configurator\param;
use function Symfony\Component\DependencyInjection\Loader\Configurator\service;
use function Symfony\Component\DependencyInjection\Loader\Configurator\service_closure;
use function Symfony\Component\DependencyInjection\Loader\Configurator\tagged_iterator;

/**
 * CronWatch in a Symfony app. Register it in config/bundles.php
 * (`Cronwatch\Symfony\CronwatchBundle::class => ['all' => true]`) and
 * configure it in config/packages/cronwatch.yaml. It gives the client as
 * the Cronwatch\Cronwatch service, watches every Scheduler message and the
 * Messenger messages marked #[Cronwatch\Watch], adds `cronwatch:check` and
 * a schedule that runs the check every five minutes, and the dashboard's
 * routes (@CronwatchBundle/config/routes.php). See DESIGN.md.
 */
final class CronwatchBundle extends AbstractBundle
{
    protected string $extensionAlias = 'cronwatch';

    public function getPath(): string
    {
        return __DIR__;
    }

    public function configure(DefinitionConfigurator $definition): void
    {
        $definition->rootNode()
            ->children()
                ->scalarNode('store')->defaultNull()->info('A store URL (mysql://, postgresql://, sqlite:///path, memory); default DATABASE_URL, else var/cronwatch.db')->end()
                ->scalarNode('store_service')->defaultNull()->info('The id of a Cronwatch\Store\Store service to use instead')->end()
                ->scalarNode('table_prefix')->defaultValue('cronwatch_')->end()
                ->booleanNode('create_tables')->defaultTrue()->end()
                ->arrayNode('alerts')->addDefaultsIfNotSet()->children()
                    ->arrayNode('mailer')->addDefaultsIfNotSet()->children()
                        ->arrayNode('to')
                            ->beforeNormalization()->ifString()->then(fn (string $v) => array_values(array_filter(array_map('trim', explode(',', $v)))))->end()
                            ->scalarPrototype()->end()
                        ->end()
                        ->scalarNode('from')->defaultNull()->end()
                        ->scalarNode('subject_prefix')->defaultNull()->end()
                    ->end()->end()
                    ->scalarNode('slack')->defaultNull()->end()
                    ->scalarNode('discord')->defaultNull()->end()
                    ->arrayNode('webhook')->addDefaultsIfNotSet()->children()
                        ->scalarNode('url')->defaultNull()->end()
                        ->scalarNode('secret')->defaultNull()->end()
                    ->end()->end()
                    ->booleanNode('log')->defaultFalse()->info('Also write alerts to the logger (they go there anyway when no channel is set)')->end()
                    ->arrayNode('services')->scalarPrototype()->end()->info('Ids of Cronwatch\Alerts\AlertChannel services')->end()
                ->end()->end()
                ->arrayNode('triage')->addDefaultsIfNotSet()->children()
                    ->booleanNode('enabled')->defaultFalse()->end()
                    ->scalarNode('model')->defaultNull()->end()
                    ->scalarNode('context')->defaultNull()->end()
                ->end()->end()
                ->scalarNode('cron_secret')->defaultNull()->info('The secret handler() and /api/check take; default CRON_SECRET, false for none')->end()
                ->scalarNode('retention')->defaultValue('30d')->end()
                ->arrayNode('defaults')->variablePrototype()->end()->end()
                ->enumNode('deliver')->values(['now', 'check'])->defaultValue('now')->end()
                ->arrayNode('scheduler')->addDefaultsIfNotSet()->children()
                    ->booleanNode('watch')->defaultTrue()->end()
                    ->arrayNode('exclude')->scalarPrototype()->end()->end()
                    ->arrayNode('jobs')->normalizeKeys(false)->useAttributeAsKey('job', false)->variablePrototype()->end()
                        ->info('Options by job name (the name, or false to leave the message out)')->end()
                ->end()->end()
                ->arrayNode('messenger')->addDefaultsIfNotSet()->children()
                    ->booleanNode('watch')->defaultTrue()->end()
                ->end()->end()
                ->arrayNode('check')->addDefaultsIfNotSet()->children()
                    ->booleanNode('schedule')->defaultTrue()->info('The "cronwatch" schedule: consume scheduler_cronwatch')->end()
                    ->scalarNode('frequency')->defaultValue('5 minutes')->end()
                ->end()->end()
                ->arrayNode('dashboard')->addDefaultsIfNotSet()->children()
                    ->scalarNode('token')->defaultNull()->end()
                    ->scalarNode('role')->defaultValue('ROLE_ADMIN')->end()
                ->end()->end()
            ->end();
    }

    /** @param array<string, mixed> $config */
    public function loadExtension(array $config, ContainerConfigurator $container, ContainerBuilder $builder): void
    {
        $services = $container->services();
        $channels = array_map(fn (string $id) => service($id), $config['alerts']['services']);
        $services->set(Cronwatch::class)
            ->factory([ClientFactory::class, 'client'])
            ->args([
                $config,
                param('kernel.project_dir'),
                service('logger')->nullOnInvalid(),
                service('mailer.mailer')->nullOnInvalid(),
                $channels,
                $config['store_service'] !== null ? service((string) $config['store_service']) : null,
            ])
            ->tag('monolog.logger', ['channel' => 'cronwatch'])
            ->public();
        $services->alias('cronwatch', Cronwatch::class)->public();

        $scheduler = interface_exists('Symfony\Component\Scheduler\ScheduleProviderInterface');
        $messenger = interface_exists('Symfony\Component\Messenger\MessageBusInterface');
        if ($scheduler) {
            $services->set(ScheduledMessages::class)
                ->args([
                    service_closure(Cronwatch::class),
                    tagged_iterator('scheduler.schedule_provider', 'name'),
                    $config['scheduler'],
                    $messenger && $config['messenger']['watch'],
                ]);
            if ($config['scheduler']['watch']) {
                $services->set(SchedulerSubscriber::class)
                    ->args([service_closure(Cronwatch::class), service(ScheduledMessages::class)])
                    ->tag('kernel.event_subscriber');
            }
        }
        $services->set(CheckMessageHandler::class)
            ->args([service_closure(Cronwatch::class), $scheduler ? service(ScheduledMessages::class) : null])
            ->public();
        if ($messenger) {
            $services->get(CheckMessageHandler::class)->tag('messenger.message_handler', ['handles' => CheckMessage::class]);
            if ($config['messenger']['watch']) {
                $services->set(MessengerSubscriber::class)
                    ->args([service_closure(Cronwatch::class), $scheduler ? service(ScheduledMessages::class) : null])
                    ->tag('kernel.event_subscriber');
            }
        }
        if ($scheduler && $messenger && $config['check']['schedule']) {
            $services->set(CheckSchedule::class)
                ->args([(string) $config['check']['frequency']])
                ->tag('scheduler.schedule_provider', ['name' => 'cronwatch']);
        }
        $services->set(CheckCommand::class)
            ->args([service(CheckMessageHandler::class)])
            ->tag('console.command', ['command' => 'cronwatch:check']);
        $services->set(DashboardController::class)
            ->args([
                service_closure(Cronwatch::class),
                service('security.authorization_checker')->nullOnInvalid(),
                $config['dashboard']['role'],
                $config['dashboard']['token'],
            ])
            ->tag('controller.service_arguments')
            ->public();
    }

    public function boot(): void
    {
        $container = $this->container;
        if ($container === null || !$container->hasParameter('kernel.environment')) {
            return;
        }
        // The environment when no variable names one: the kernel's.
        $environment = (string) $container->getParameter('kernel.environment');
        Env::setFallback(fn () => $environment);
    }
}
