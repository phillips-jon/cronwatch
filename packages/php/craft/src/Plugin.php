<?php

declare(strict_types=1);

namespace Cronwatch\Craft;

use Cronwatch\Craft\models\Settings;
use Craft;
use craft\base\Model;
use craft\base\Plugin as BasePlugin;
use craft\console\ErrorHandler as ConsoleErrorHandler;
use craft\events\ExceptionEvent;
use craft\events\RegisterUrlRulesEvent;
use craft\events\RegisterUserPermissionsEvent;
use craft\services\UserPermissions;
use craft\web\UrlManager;
use yii\base\ActionEvent;
use yii\base\Controller;
use yii\base\Event;
use yii\queue\ExecEvent;
use yii\queue\Queue;

/**
 * CronWatch for Craft CMS: queue jobs and console commands watched, the
 * check (`craft cronwatch/check`), the store in Craft's database, the
 * dashboard in the Control Panel and the channels in the plugin settings.
 *
 * @property-read Recorder $recorder
 */
final class Plugin extends BasePlugin
{
    /** Add or change alert channels (an AlertsEvent). */
    public const EVENT_ALERTS = 'cronwatchAlerts';
    /** Silence, forget and check jobs from the dashboard (viewing it is accessPlugin-cronwatch). */
    public const PERMISSION_MANAGE = 'cronwatch-manage';

    public string $schemaVersion = '1.0.0';
    public bool $hasCpSettings = true;
    public bool $hasCpSection = true;

    private ?Recorder $recorderInstance = null;

    public function getRecorder(): Recorder
    {
        return $this->recorderInstance ??= new Recorder($this);
    }

    public function init(): void
    {
        parent::init();
        $recorder = fn (): Recorder => $this->getRecorder();

        // Queue jobs that opt in, each attempt a run (every queue: Craft's and any other yii2-queue).
        Event::on(Queue::class, Queue::EVENT_BEFORE_EXEC, fn (ExecEvent $e) => $recorder()->jobStarting($e));
        Event::on(Queue::class, Queue::EVENT_AFTER_EXEC, fn (ExecEvent $e) => $recorder()->jobFinished($e));
        Event::on(Queue::class, Queue::EVENT_AFTER_ERROR, fn (ExecEvent $e) => $recorder()->jobFailed($e));

        if (Craft::$app->getRequest()->getIsConsoleRequest()) {
            // Console commands the settings list or a WatchCommand behavior marks.
            Event::on(\yii\console\Controller::class, Controller::EVENT_BEFORE_ACTION, fn (ActionEvent $e) => $recorder()->commandStarting($e));
            Event::on(\yii\console\Controller::class, Controller::EVENT_AFTER_ACTION, fn (ActionEvent $e) => $recorder()->commandFinished($e));
            Event::on(ConsoleErrorHandler::class, ConsoleErrorHandler::EVENT_BEFORE_HANDLE_EXCEPTION, fn (ExceptionEvent $e) => $recorder()->commandFailed($e->exception));
        }

        Event::on(UrlManager::class, UrlManager::EVENT_REGISTER_CP_URL_RULES, function (RegisterUrlRulesEvent $event): void {
            $event->rules['cronwatch'] = 'cronwatch/dashboard/index';
            $event->rules['cronwatch/view'] = 'cronwatch/dashboard/view';
        });
        Event::on(UrlManager::class, UrlManager::EVENT_REGISTER_SITE_URL_RULES, function (RegisterUrlRulesEvent $event): void {
            // The JSON API for @cronwatch/mcp: 404 until a token is set. GET
            // /cronwatch/api itself (the library and its version) has no path after it.
            $event->rules['cronwatch/api'] = 'cronwatch/api/index';
            $event->rules['cronwatch/api/<path:.*>'] = 'cronwatch/api/index';
        });
        Event::on(UserPermissions::class, UserPermissions::EVENT_REGISTER_PERMISSIONS, function (RegisterUserPermissionsEvent $event): void {
            $event->permissions[] = [
                'heading' => 'CronWatch',
                'permissions' => [
                    self::PERMISSION_MANAGE => ['label' => 'Silence, forget and check jobs from the dashboard'],
                ],
            ];
        });
    }

    protected function createSettingsModel(): ?Model
    {
        return new Settings();
    }

    protected function settingsHtml(): ?string
    {
        $file = Craft::$app->getConfig()->getConfigFromFile($this->handle);
        return Craft::$app->getView()->renderTemplate('cronwatch/_settings.twig', [
            'settings' => $this->getSettings(),
            // Settings config/cronwatch.php sets win over the form, so their fields are shown disabled.
            'overrides' => is_array($file) ? array_keys($file) : [],
        ]);
    }

    public function afterSaveSettings(): void
    {
        parent::afterSaveSettings();
        $this->recorderInstance?->reset();
    }
}
