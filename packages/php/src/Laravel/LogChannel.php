<?php

declare(strict_types=1);

namespace Cronwatch\Laravel;

use Cronwatch\Alert;
use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\AlertType;

/**
 * Writes each alert to the app's log (a channel of config/logging.php, or
 * the default): a warning for a problem, info for a recovery. The channel
 * alerts go to when no other is set.
 */
final class LogChannel implements AlertChannel
{
    public function __construct(private readonly object $log, private readonly ?string $channel = null)
    {
    }

    public function name(): string
    {
        return 'log';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $logger = $this->channel !== null ? $this->log->channel($this->channel) : $this->log;
        $line = "[cronwatch] {$alert->title}\n{$alert->message}";
        if ($alert->triage !== null) {
            $line .= "\n\nTriage: {$alert->triage}";
        }
        $details = ['job' => $alert->job, 'type' => $alert->type, 'at' => $alert->at];
        if ($alert->type === AlertType::RECOVERED) {
            $logger->info($line, $details);
        } else {
            $logger->warning($line, $details);
        }
    }
}
