<?php

declare(strict_types=1);

namespace Cronwatch\Laravel\Http;

use Illuminate\Contracts\Auth\Access\Gate;
use Illuminate\Http\Request;

/**
 * Who may open the dashboard: the viewCronwatch gate, asked with the signed
 * in user (or none). By default it lets anyone in the local environment
 * only; an app widens it in a service provider's boot():
 *
 *     Gate::define('viewCronwatch', fn (User $user) => $user->is_admin);
 *
 * A request carrying a bearer token skips the gate: the dashboard checks
 * the token itself (CRONWATCH_TOKEN, or CRON_SECRET for /api/check), for
 * @cronwatch/mcp and a platform cron, which have no session.
 */
final class Authorize
{
    public const GATE = 'viewCronwatch';

    public function __construct(private readonly Gate $gate)
    {
    }

    public function handle(Request $request, \Closure $next): mixed
    {
        if (self::hasBearer($request)) {
            return $next($request);
        }
        if (!$this->gate->check(self::GATE, [$request->user()])) {
            abort(403);
        }
        return $next($request);
    }

    public static function hasBearer(Request $request): bool
    {
        return preg_match('/^Bearer\s/i', (string) $request->headers->get('authorization', '')) === 1;
    }
}
