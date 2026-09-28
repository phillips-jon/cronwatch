<?php

declare(strict_types=1);

namespace Cronwatch\Craft;

use Cronwatch\Alert;
use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\AlertType;
use Craft;

/**
 * Writes each alert to Craft's log, category "cronwatch": a warning for a
 * problem, info for a recovery. Where alerts go when no channel is set.
 */
final class LogChannel implements AlertChannel
{
    public function name(): string
    {
        return 'log';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $line = "{$alert->title}\n{$alert->message}" . ($alert->triage !== null ? "\n\nTriage: {$alert->triage}" : '');
        if ($alert->type === AlertType::RECOVERED) {
            Craft::info($line, 'cronwatch');
        } else {
            Craft::warning($line, 'cronwatch');
        }
    }
}
