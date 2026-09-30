<?php

declare(strict_types=1);

namespace Drupal\cwt_fixtures\Plugin\QueueWorker;

use Cronwatch\Watch;
use Drupal\Core\Plugin\ContainerFactoryPluginInterface;
use Drupal\Core\Queue\QueueWorkerBase;
use Drupal\Core\State\StateInterface;
use Symfony\Component\DependencyInjection\ContainerInterface;

/**
 * A worker watched by its attribute, made through create().
 *
 * @QueueWorker(
 *   id = "cwt_marked",
 *   title = @Translation("CronWatch marked queue"),
 *   cron = {"time" = 5}
 * )
 */
#[Watch(name: 'cwt-marked', description: 'Marks each item', grace: '1h', failuresBeforeAlert: 2)]
final class Marked extends QueueWorkerBase implements ContainerFactoryPluginInterface {

  public function __construct(array $configuration, $plugin_id, $plugin_definition, private readonly StateInterface $state) {
    parent::__construct($configuration, $plugin_id, $plugin_definition);
  }

  /**
   * {@inheritdoc}
   */
  public static function create(ContainerInterface $container, array $configuration, $plugin_id, $plugin_definition) {
    return new self($configuration, $plugin_id, $plugin_definition, $container->get('state'));
  }

  /**
   * {@inheritdoc}
   */
  public function processItem($data) {
    $this->state->set('cwt.marked', ($this->state->get('cwt.marked', 0)) + 1);
    return 'marked ' . $data;
  }

}
