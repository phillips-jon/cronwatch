<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Support;

use Cronwatch\Alert;
use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\ChannelContext;

/** A channel that keeps every alert it is sent. */
final class Capture implements AlertChannel
{
    /** @var list<Alert> */
    public array $alerts = [];

    public function name(): string
    {
        return 'capture';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $this->alerts[] = $alert;
    }

    /** @return list<string> */
    public function types(): array
    {
        return array_map(fn (Alert $a) => $a->type, $this->alerts);
    }
}
