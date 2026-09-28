<?php

declare(strict_types=1);

namespace Drupal\cronwatch;

use Drupal\Core\Cron;
use Drupal\Core\DependencyInjection\ContainerBuilder;
use Drupal\Core\DependencyInjection\ServiceProviderBase;

/**
 * Makes core's cron service WatchedCron, which records each run.
 *
 * Only when the service is core's own class: a module that replaced it
 * (Ultimate Cron runs each job itself) is left alone, and the container
 * parameter cronwatch.watching_cron says so, for the settings page.
 */
class CronwatchServiceProvider extends ServiceProviderBase {

  /**
   * {@inheritdoc}
   */
  public function alter(ContainerBuilder $container) {
    $watching = FALSE;
    if ($container->hasDefinition('cron')) {
      $definition = $container->getDefinition('cron');
      if (ltrim((string) $definition->getClass(), '\\') === Cron::class) {
        $definition->setClass(WatchedCron::class);
        // Drupal 10 declares the service lazy, through a proxy class
        // generated for core's class; there is none for this one, and the
        // service is cheap to make (its arguments are services every request
        // has), so it is made when first asked for, as Drupal 11 makes it.
        $definition->setLazy(FALSE);
        $watching = TRUE;
      }
    }
    $container->setParameter('cronwatch.watching_cron', $watching);
  }

}
