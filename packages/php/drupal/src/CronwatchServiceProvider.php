<?php

declare(strict_types=1);

namespace Drupal\cronwatch;

use Drupal\Core\Cron;
use Drupal\Core\DependencyInjection\ContainerBuilder;
use Drupal\Core\DependencyInjection\ServiceProviderBase;

/**
 * Makes core's cron service WatchedCron, which records each run.
 *
 * Only when the service is core's own class. A module that replaces it
 * after this has run is seen by CronServicePass, which runs once every
 * module's alter() has: Ultimate Cron's service is watched there, and any
 * other is left alone, the container parameter cronwatch.watching_cron
 * saying so, for the settings page.
 */
class CronwatchServiceProvider extends ServiceProviderBase {

  /**
   * {@inheritdoc}
   */
  public function register(ContainerBuilder $container) {
    $container->addCompilerPass(new CronServicePass());
  }

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
