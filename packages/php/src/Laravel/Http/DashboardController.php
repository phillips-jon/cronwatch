<?php

declare(strict_types=1);

namespace Cronwatch\Laravel\Http;

use Cronwatch\FromEnv;
use Cronwatch\Cronwatch;
use Cronwatch\Laravel\Settings;
use Cronwatch\Web\HttpFoundation;
use Illuminate\Contracts\Auth\Access\Gate;
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
    public function __construct(private readonly Cronwatch $cw, private readonly Repository $config, private readonly Gate $gate)
    {
    }

    public function __invoke(Request $request): mixed
    {
        $path = trim((string) $this->config->get('cronwatch.dashboard.path', 'cronwatch'), '/');
        $base = rtrim($request->getBaseUrl(), '/') . ($path === '' ? '' : "/{$path}");
        // Served open only to a request the gate lets in, asked again here rather
        // than trusted to the route's middleware, which the config may change.
        $open = !Authorize::hasBearer($request) && $this->gate->check(Authorize::GATE, [$request->user()]);
        $dashboard = $this->cw->routes(
            token: $open ? null : self::token($this->config),
            basePath: $base,
            origin: $request->getSchemeAndHttpHost(),
        );
        return HttpFoundation::toResponse($dashboard->handle(HttpFoundation::toRequest($request)), true);
    }

    /**
     * The dashboard's token: the config's, else CRONWATCH_TOKEN as Laravel's
     * env() reads it (Settings::secret()). With neither, the library's
     * default makes a development token or stays locked; but when the raw
     * environment holds a value env() did not take (`CRONWATCH_TOKEN=null`),
     * that default would read it as the token, so the dashboard asks for a
     * random one instead, which no request carries.
     */
    private static function token(Repository $config): string|FromEnv
    {
        $token = Settings::secret($config, 'dashboard.token', 'CRONWATCH_TOKEN');
        if ($token !== null) {
            return $token;
        }
        return Settings::rawOnly('CRONWATCH_TOKEN') ? bin2hex(random_bytes(32)) : FromEnv::Read;
    }
}
