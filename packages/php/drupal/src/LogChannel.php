<?php

declare(strict_types=1);

namespace Drupal\cronwatch;

use Cronwatch\Alert;
use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\AlertType;
use Psr\Log\LoggerInterface;

/**
 * Writes each alert to Drupal's log, the cronwatch channel.
 *
 * A warning for a problem, a notice for a recovery. Where alerts go when no
 * other channel is set.
 */
final class LogChannel implements AlertChannel {

  public function __construct(private readonly LoggerInterface $logger) {
  }

  /**
   * {@inheritdoc}
   */
  public function name(): string {
    return 'log';
  }

  /**
   * {@inheritdoc}
   */
  public function send(Alert $alert, ChannelContext $context): void {
    $text = $alert->message . ($alert->triage !== NULL ? "\n\nTriage: {$alert->triage}" : '');
    $variables = ['@title' => $alert->title, '@message' => $text];
    if ($alert->type === AlertType::RECOVERED) {
      $this->logger->notice('@title: @message', $variables);
    }
    else {
      $this->logger->warning('@title: @message', $variables);
    }
  }

}
