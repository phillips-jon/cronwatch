<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Cronwatch\Cronwatch;
use Cronwatch\Web\HttpFoundation;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * The dashboard and JSON API, mounted by importing the bundle's routes
 * under a prefix (config/routes/cronwatch.yaml):
 *
 *     cronwatch:
 *         resource: '@CronwatchBundle/config/routes.php'
 *         prefix: /cronwatch
 *
 * Put it behind the app's security (an access_control rule for the
 * prefix). A signed-in user granted the configured role (ROLE_ADMIN by
 * default) is served with no token of the dashboard's own, the app's
 * sign-in standing for it; anyone else, and every request carrying a
 * bearer token (@cronwatch/mcp, a platform cron calling /api/check), must
 * present the dashboard's token (CRONWATCH_TOKEN, or CRON_SECRET for
 * /api/check), so a prefix left outside the firewall is still closed. The
 * routes refuse cross-site writes themselves; the origin they compare with
 * is the one Symfony sees (its trusted proxies apply).
 */
final class DashboardController
{
    /** @param \Closure(): Cronwatch $client */
    public function __construct(
        private readonly \Closure $client,
        private readonly ?object $authorization = null,
        private readonly ?string $role = 'ROLE_ADMIN',
        private readonly ?string $token = null,
    ) {
    }

    public function __invoke(Request $request, string $path = ''): Response
    {
        $info = $request->getPathInfo();
        $rest = $path === '' ? '' : '/' . ltrim($path, '/');
        $mount = $rest !== '' && str_ends_with($info, $rest) ? substr($info, 0, -strlen($rest)) : rtrim($info, '/');
        $base = rtrim($request->getBaseUrl(), '/') . rtrim($mount, '/');
        $bearer = preg_match('/^Bearer\s/i', (string) $request->headers->get('authorization', '')) === 1;
        $open = !$bearer && $this->granted();
        $dashboard = ($this->client)()->routes(
            token: $open ? false : ($this->token !== null && $this->token !== '' ? $this->token : null),
            basePath: $base,
            origin: $request->getSchemeAndHttpHost(),
        );
        $response = HttpFoundation::toResponse($dashboard->handle(HttpFoundation::toRequest($request)));
        \assert($response instanceof Response);
        return $response;
    }

    private function granted(): bool
    {
        if ($this->authorization === null || $this->role === null || $this->role === '') {
            return false;
        }
        try {
            return (bool) $this->authorization->isGranted($this->role);
        } catch (\Throwable) {
            // No firewall covers the request: no one is signed in.
            return false;
        }
    }
}
