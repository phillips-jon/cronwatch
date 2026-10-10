<?php

declare(strict_types=1);

namespace Cronwatch\Craft\controllers;

use Cronwatch\Bridge\EmbeddedDashboard;
use Cronwatch\Craft\Plugin;
use Cronwatch\Web\Dashboard;
use Cronwatch\Web\Request;
use Craft;
use craft\helpers\UrlHelper;
use craft\web\Controller;
use yii\web\Response;

/**
 * The library's dashboard in the Control Panel, behind Craft's sign-in.
 *
 * admin/cronwatch is a Control Panel page with the dashboard in a frame
 * (the dashboard is a page of its own, with its own styles and a strict
 * CSP); admin/cronwatch/view?cw=<path> is the dashboard's page at <path>.
 * Both need the plugin's own permission (accessPlugin-cronwatch), which
 * Craft gives the plugin's section; the dashboard runs open (token null),
 * Craft's sign-in standing for its token. A change (silence, forget, "Run
 * check now", all POSTs) also needs the cronwatch-manage permission and
 * Craft's CSRF token, which every form carries as a hidden field, besides
 * the dashboard's own same-origin check. Links, forms, and redirects are
 * rewritten to that route (see EmbeddedDashboard), and the app shell is
 * left out.
 */
final class DashboardController extends Controller
{
    public function actionIndex(): Response
    {
        $this->requirePermission('accessPlugin-cronwatch');
        $job = (string) $this->request->getQueryParam('job', '');
        return $this->renderTemplate('cronwatch/_index.twig', [
            'src' => self::viewUrl($job === '' ? '/' : '/jobs/' . rawurlencode($job)),
        ]);
    }

    public function actionView(): Response
    {
        $this->requirePermission('accessPlugin-cronwatch');
        $method = strtoupper($this->request->getMethod());
        $path = (string) $this->request->getQueryParam('cw', '/');
        $recorder = Plugin::getInstance()->getRecorder();
        // Craft's sign-in stands for the token here, so a bearer means nothing:
        // left in, it would let a GET of /api/check run the check for a user
        // who may only look.
        $inner = self::withoutBearer(EmbeddedDashboard::request(Request::fromGlobals(), $path, ['cw', 'p', $this->request->csrfParam]));
        if ($method !== 'GET' && $method !== 'HEAD') {
            // Craft has checked the CSRF token by now.
            $this->requirePermission(Plugin::PERMISSION_MANAGE);
            if (self::isCheck(substr($inner->path, strlen(EmbeddedDashboard::MARKER)))) {
                // The plugin's check: the settings' jobs declared first.
                $recorder->prepare();
            }
        }
        $origin = $this->request->getHostInfo();
        $dashboard = new Dashboard($recorder->client(), token: null, basePath: EmbeddedDashboard::MARKER, origin: $origin);
        $field = '<input type="hidden" name="' . htmlspecialchars($this->request->csrfParam, ENT_QUOTES) . '" value="' . htmlspecialchars((string) $this->request->getCsrfToken(), ENT_QUOTES) . '">';
        $answer = EmbeddedDashboard::rewrite(
            $dashboard->handle($inner),
            fn (string $path, array $query): string => self::viewUrl($path, $query),
            null,
            $field,
        );

        $response = $this->response;
        $response->format = Response::FORMAT_RAW;
        $response->setStatusCode($answer->status);
        foreach ($answer->headers as $name => $value) {
            $response->getHeaders()->set($name, $value);
        }
        $response->content = $answer->body;
        return $response;
    }

    /**
     * Whether a path of the dashboard's is its check, /check or /api/check,
     * read as the dashboard reads it: empty segments left out, each one
     * percent-decoded.
     *
     * @internal
     */
    public static function isCheck(string $path): bool
    {
        $parts = [];
        foreach (explode('/', $path) as $part) {
            if ($part !== '') {
                $parts[] = rawurldecode($part);
            }
        }
        return $parts === ['check'] || $parts === ['api', 'check'];
    }

    /** The request without its Authorization header. */
    private static function withoutBearer(Request $request): Request
    {
        $headers = $request->headers;
        unset($headers['authorization']);
        return new Request($request->method, $request->path, $request->query, $headers, static fn (): string => $request->body(), $request->origin, $request->mount, $request->form);
    }

    /**
     * The dashboard's page at a path, in the Control Panel.
     *
     * @param array<string, string> $query the page's own query
     */
    private static function viewUrl(string $path, array $query = []): string
    {
        return UrlHelper::cpUrl('cronwatch/view', ['cw' => $path] + $query);
    }
}
