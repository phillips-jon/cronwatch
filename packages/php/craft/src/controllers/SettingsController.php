<?php

declare(strict_types=1);

namespace Cronwatch\Craft\controllers;

use Cronwatch\Bridge\TestAlert;
use Cronwatch\Craft\Plugin;
use Craft;
use craft\helpers\UrlHelper;
use craft\web\Controller;
use yii\web\Response;

/**
 * The settings page's "Send a test alert": one alert to every channel the
 * saved settings name (and any a Plugin::EVENT_ALERTS listener adds), each
 * channel's answer shown back on the page. Plugin settings are for admins in
 * the Control Panel, so this is too, and it is a POST with Craft's CSRF token.
 */
final class SettingsController extends Controller
{
    public function actionTestAlert(): Response
    {
        $this->requireCpRequest();
        $this->requirePostRequest();
        $this->requireAdmin(false);
        $channels = Plugin::getInstance()->getRecorder()->channels();
        $session = Craft::$app->getSession();
        if ($channels === []) {
            $session->setError(Craft::t('cronwatch', 'No alert channel is set, so alerts go to Craft’s log. Save a channel first.'));
            return $this->redirect(UrlHelper::cpUrl('settings/plugins/cronwatch'));
        }
        $lines = [];
        $failed = false;
        foreach (TestAlert::send($channels, UrlHelper::baseSiteUrl()) as $result) {
            if ($result['ok']) {
                $lines[] = Craft::t('cronwatch', 'Sent through {channel}.', ['channel' => $result['channel']]) . ($result['message'] !== '' ? ' ' . $result['message'] : '');
            } else {
                $failed = true;
                $lines[] = Craft::t('cronwatch', '{channel} failed: {message}', ['channel' => $result['channel'], 'message' => $result['message']]);
            }
        }
        $failed ? $session->setError(implode(' ', $lines)) : $session->setNotice(implode(' ', $lines));
        return $this->redirect(UrlHelper::cpUrl('settings/plugins/cronwatch'));
    }
}
