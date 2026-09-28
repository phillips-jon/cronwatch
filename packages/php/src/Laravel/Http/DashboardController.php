<?php

declare(strict_types=1);

namespace Cronwatch\Laravel\Http;

use Cronwatch\Cronwatch;
use Cronwatch\Web\HttpFoundation;
use Illuminate\Contracts\Config\Repository;
use Illuminate\Http\Request;

/**
 * The dashboard and JSON API under the configured path (default
 * /cronwatch), every page of it through the library's one handler. A
 * request that passed the route's middleware (the viewCronwatch gate, by
 * default) is served with no token of the dashboard's own, the app's
 * sign-in standing for it; a request carrying a bearer token must carry
 * the dashboard's token (or CRON_SECRET for /api/check). The routes refuse
 * cross-site writes themselves, so Laravel's CSRF middleware is left off
 * them; the origin they compare with is the one Laravel sees (its trusted
 * proxies apply).
 */
final class DashboardController
{
    public function __construct(private readonly Cronwatch $cw, private readonly Repository $config)
    {
    }

    public function __invoke(Request $request): mixed
    {
        $path = trim((string) $this->config->get('cronwatch.dashboard.path', 'cronwatch'), '/');
        $base = rtrim($request->getBaseUrl(), '/') . ($path === '' ? '' : "/{$path}");
        $token = $this->config->get('cronwatch.dashboard.token');
        $dashboard = $this->cw->routes(
            token: Authorize::hasBearer($request) ? (is_string($token) && $token !== '' ? $token : null) : false,
            basePath: $base,
            origin: $request->getSchemeAndHttpHost(),
        );
        return HttpFoundation::toResponse($dashboard->handle(HttpFoundation::toRequest($request)), true);
    }
}
