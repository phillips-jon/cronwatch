<?php

declare(strict_types=1);

namespace cwt;

use Cronwatch\Alert;
use Cronwatch\Craft\AlertsEvent;
use Cronwatch\Craft\Plugin;
use Craft;
use yii\base\Event;

/**
 * Fixtures for the Craft plugin's tests: console commands (cwt/task/...,
 * cwt/behaved), queue jobs, and an alert channel that appends every alert
 * to storage/runtime/cwt-alerts.json.
 */
final class Module extends \yii\base\Module
{
    public function init(): void
    {
        Craft::setAlias('@cwt', __DIR__);
        $this->controllerNamespace = Craft::$app->getRequest()->getIsConsoleRequest() ? 'cwt\\console\\controllers' : 'cwt\\controllers';
        parent::init();
        Event::on(Plugin::class, Plugin::EVENT_ALERTS, function (AlertsEvent $event): void {
            $event->channels[] = function (Alert $alert): void {
                $file = Craft::getAlias('@storage/runtime/cwt-alerts.json');
                $alerts = is_file($file) ? (array) json_decode((string) file_get_contents($file), true) : [];
                $alerts[] = ['type' => $alert->type, 'job' => $alert->job, 'title' => $alert->title];
                file_put_contents($file, json_encode($alerts));
            };
        });
    }
}
