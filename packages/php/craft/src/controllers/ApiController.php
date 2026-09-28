<?php

declare(strict_types=1);

namespace Cronwatch\Craft\controllers;

use Cronwatch\Craft\Plugin;
use Cronwatch\Env;
use Cronwatch\Web\Dashboard;
use Cronwatch\Web\Request;
use craft\web\Controller;
use yii\web\NotFoundHttpException;
use yii\web\Response;

/**
 * The JSON API for @cronwatch/mcp, at /cronwatch/api/... on the site, with
 * the dashboard's token (the apiToken setting, else CRONWATCH_TOKEN) as a
 * bearer token. Without a token it is not there (404). Only the /api paths
 * are served; the dashboard's pages are in the Control Panel.
 */
final class ApiController extends Controller
{
    protected array|bool|int $allowAnonymous = self::ALLOW_ANONYMOUS_LIVE;
    public $enableCsrfValidation = false;

    public function actionIndex(): Response
    {
        $recorder = Plugin::getInstance()->getRecorder();
        $token = $recorder->settings()->value('apiToken');
        $token = $token !== '' ? $token : (string) Env::read('CRONWATCH_TOKEN');
        if ($token === '') {
            throw new NotFoundHttpException();
        }
        $request = Request::fromGlobals();
        $at = strpos($request->path, '/cronwatch/api');
        if ($at === false) {
            throw new NotFoundHttpException();
        }
        if (strtoupper($request->method) === 'POST' && str_ends_with(rtrim($request->path, '/'), '/cronwatch/api/check')) {
            $recorder->prepare();
        }
        $dashboard = new Dashboard($recorder->client(), token: $token, basePath: substr($request->path, 0, $at) . '/cronwatch');
        $answer = $dashboard->handle($request);

        $response = $this->response;
        $response->format = Response::FORMAT_RAW;
        $response->setStatusCode($answer->status);
        foreach ($answer->headers as $name => $value) {
            $response->getHeaders()->set($name, $value);
        }
        $response->content = $answer->body;
        return $response;
    }
}
