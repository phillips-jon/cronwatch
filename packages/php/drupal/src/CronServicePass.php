<?php

declare(strict_types=1);

namespace Drupal\cronwatch;

use Drupal\cronwatch\UltimateCron\WatchedUltimateCron;
use Symfony\Component\DependencyInjection\Compiler\CompilerPassInterface;
use Symfony\Component\DependencyInjection\ContainerBuilder;

/**
 * Says which cron service the site ended up with, once every module has had
 * its say, and watches Ultimate Cron's.
 *
 * CronwatchServiceProvider::alter() makes core's service WatchedCron, but a
 * module whose alter() runs after it can replace the class again: Ultimate
 * Cron does, whatever the class was. This pass runs after every alter() (and
 * after Drupal 10 has put a lazy service behind its proxy, so the original
 * definition is the one changed). Ultimate Cron's service becomes
 * WatchedUltimateCron, a subclass that records each cron run as
 * "drupal:cron"; its jobs are recorded by WatchedCronJob (see
 * cronwatch_entity_type_alter()). The container parameters
 * cronwatch.cron_service ("core", "ultimate_cron", or "" for a service
 * CronWatch does not know) and cronwatch.watching_cron say which, for the
 * recorder and the settings page.
 */
final class CronServicePass implements CompilerPassInterface {

  /**
   * Ultimate Cron's cron service, named as a string: the module may be absent.
   */
  public const ULTIMATE_CRON = 'Drupal\ultimate_cron\UltimateCron';

  /**
   * {@inheritdoc}
   */
  public function process(ContainerBuilder $container): void {
    if (!$container->hasDefinition('cron')) {
      return;
    }
    $id = $container->hasDefinition('drupal.proxy_original_service.cron') ? 'drupal.proxy_original_service.cron' : 'cron';
    $definition = $container->getDefinition($id);
    $class = ltrim((string) $definition->getClass(), '\\');
    $service = '';
    if ($class === WatchedCron::class) {
      $service = 'core';
    }
    elseif ($class === self::ULTIMATE_CRON) {
      $definition->setClass(WatchedUltimateCron::class);
      $service = 'ultimate_cron';
    }
    $container->setParameter('cronwatch.cron_service', $service);
    $container->setParameter('cronwatch.watching_cron', $service !== '');
  }

}
