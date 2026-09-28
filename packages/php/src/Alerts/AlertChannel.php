<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;

/**
 * Where alerts go. send() returns once the alert went out (to at least one
 * recipient) and throws when it went nowhere; the client retries an alert
 * no channel accepted at its next check.
 */
interface AlertChannel
{
    public function name(): string;

    public function send(Alert $alert, ChannelContext $context): void;
}
