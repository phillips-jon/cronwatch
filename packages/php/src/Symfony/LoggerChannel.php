<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Cronwatch\Alert;
use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\AlertType;
use Psr\Log\LoggerInterface;

/**
 * Writes each alert to the app's logger (Monolog's "cronwatch" channel when
 * the app has Monolog): a warning for a problem, info for a recovery. The
 * channel alerts go to when no other is set.
 */
final class LoggerChannel implements AlertChannel
{
    public function __construct(private readonly LoggerInterface $logger)
    {
    }

    public function name(): string
    {
        return 'log';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $line = "[cronwatch] {$alert->title}\n{$alert->message}";
        if ($alert->triage !== null) {
            $line .= "\n\nTriage: {$alert->triage}";
        }
        $details = ['job' => $alert->job, 'type' => $alert->type, 'at' => $alert->at];
        if ($alert->type === AlertType::RECOVERED) {
            $this->logger->info($line, $details);
        } else {
            $this->logger->warning($line, $details);
        }
    }
}
