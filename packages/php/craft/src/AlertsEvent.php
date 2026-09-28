<?php

declare(strict_types=1);

namespace Cronwatch\Craft;

use yii\base\Event;

/**
 * Plugin::EVENT_ALERTS: the alert channels, to add to or change.
 *
 *     Event::on(Plugin::class, Plugin::EVENT_ALERTS, function (AlertsEvent $event) {
 *         $event->channels[] = new \Cronwatch\Alerts\Discord(App::env('DISCORD_WEBHOOK_URL'));
 *     });
 */
final class AlertsEvent extends Event
{
    /** @var list<mixed> the library's channels, or callables taking the Cronwatch\Alert */
    public array $channels = [];
}
