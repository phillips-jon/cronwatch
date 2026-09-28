<?php

declare(strict_types=1);

namespace Drupal\cronwatch\Drush\Commands;

use Drupal\cronwatch\Recorder;
use Drush\Attributes as CLI;
use Drush\Commands\DrushCommands;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * `drush cronwatch:check`, for the server's crontab.
 */
final class CronwatchCommands extends DrushCommands {

  public function __construct(private readonly Recorder $recorder) {
    parent::__construct();
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container): self {
    return new self($container->get('cronwatch.recorder'));
  }

  /**
   * Finds missed and stuck runs and sends what alerts are due.
   *
   * Every hook_cron and watched queue is declared as a job first. Prints the
   * line every CronWatch port prints; anything that goes wrong is an error
   * and a non-zero exit status, so cron mails it.
   */
  #[CLI\Command(name: 'cronwatch:check', aliases: ['cronwatch-check'])]
  #[CLI\Usage(name: 'drush cronwatch:check', description: 'Check every watched job now.')]
  public function check(): void {
    $this->output()->writeln($this->recorder->check()->summary());
  }

}
