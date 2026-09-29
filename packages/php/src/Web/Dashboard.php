<?php

declare(strict_types=1);

namespace Cronwatch\Web;

use Cronwatch\Cronwatch;
use Cronwatch\Duration;
use Cronwatch\Env;
use Cronwatch\JobWithRuns;
use Cronwatch\Js;

/**
 * The dashboard and the small JSON API: the SDK's routes (routes/index.ts)
 * with the same URLs, JSON, auth, CSRF rules, headers and pages, byte for
 * byte, so @cronwatch/mcp works against a PHP app as it does against a Node one.
 *
 * One core takes a Request and returns a Response (handle). Around it:
 * serve() answers the request PHP is handling now, from the superglobals,
 * with header() and echo, so a bare script is enough:
 *
 *     // public/cronwatch.php, reached as /cronwatch.php/ (or rewrite /cronwatch/ to it)
 *     $cw = require __DIR__ . '/../cronwatch.php';
 *     $cw->routes()->serve();
 *
 * and PsrHandler and PsrMiddleware put it in a PSR-15 stack (Slim, Mezzio,
 * any framework that speaks PSR-7), for apps that have psr/http-message.
 *
 * token:      required to reach anything. Send it as `Authorization: Bearer <token>`, or open
 *             the dashboard once with `?token=<token>` and a cookie is set. Defaults to
 *             CRONWATCH_TOKEN; "" counts as unset. With no token while the environment is
 *             development or test (Cronwatch\Env), the dashboard makes a random one, keeps it
 *             in a file (developmentTokenFile, default in the system's temporary directory) so
 *             every PHP request after it asks for the same one, and writes a sign-in link to
 *             the server log (error_log) when it makes it; with no token otherwise it answers
 *             503. Pass false to opt out and serve it open everywhere, for example behind your
 *             own auth (the SDK's null; PHP's null is the default). /api/check also accepts
 *             the client's cronSecret as a bearer, for a platform cron.
 * basePath:   where the routes are mounted, so links resolve. Default: the script, for a
 *             path-info URL such as /cronwatch.php/api/jobs, else "/cronwatch".
 * origin:     the public origin the dashboard is served from, such as "https://app.example.com",
 *             for an app behind a proxy whose requests carry an internal host or scheme. Used
 *             in place of the request's origin for the cross-site check on writes, the sign-in
 *             cookie's Secure flag, the Referer the redirect back after a form follows, and the
 *             development sign-in line. Read as `new URL(value).origin` reads it; anything that
 *             is not an absolute http or https URL throws InvalidArgumentException here. Takes
 *             precedence over trustProxy.
 * head:       for a host that shows the dashboard inside its own pages and loads their assets its
 *             own way: given the base path, it returns the HTML each page's head carries in
 *             place of the manifest, the icons, app.js and the inline stylesheet (Html::CSS is
 *             the stylesheet, for the host to serve as a file). The app shell's manifest,
 *             service worker, app.js and offline page are then not served, since no page asks
 *             for them; the icons still are. Default null: the pages are the SDK's.
 * empty:      HTML the board shows while there are no jobs, in place of how to declare one, for a
 *             host whose jobs come from elsewhere (the WordPress plugin's, from WP-Cron). Written
 *             as given, so escape anything in it. Default null: the SDK's text.
 * trustProxy: take the public origin from X-Forwarded-Proto and X-Forwarded-Host (the first
 *             value of each, falling back to the request's scheme or host for whichever is
 *             missing) when a request carries either. Only for an app whose proxy sets or
 *             overwrites both headers: a client can send them too. Default false.
 */
final class Dashboard
{
    public const COOKIE = 'cronwatch_token';
    public const DEFAULT_RUNS = 20;
    public const MAX_RUNS = 500;
    /** Runs per job the board reads in one go: the table's sparkline, and most jobs' lanes. */
    public const BOARD_PAGE_RUNS = 20;
    public const COOKIE_MAX_AGE = 60 * 60 * 24 * 30;

    /**
     * 'self' only for what the app shell needs: app.js (which registers the
     * service worker and nothing else), the manifest, the worker and the
     * icons. No inline script, and the pages work without any.
     */
    public const CSP = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; worker-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'";
    /** For the SVG icons, should one be opened on its own. */
    public const ASSET_CSP = "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'";
    /**
     * same-origin rather than no-referrer: under no-referrer browsers send
     * `Origin: null` on form posts, which the CSRF check would refuse, and
     * the forms redirect back to the page named by the same-origin Referer.
     */
    public const SECURITY_HEADERS = ['x-content-type-options' => 'nosniff', 'referrer-policy' => 'same-origin', 'x-robots-tag' => 'noindex'];

    public const LOCKED = 'Set CRONWATCH_TOKEN (or pass token: to $cw->routes()), or pass token: false to serve them open behind your own auth.';

    private readonly bool $optedOut;
    private readonly bool $generated;
    private ?string $token;
    private readonly ?string $basePath;
    private readonly ?string $origin;
    private readonly bool $trustProxy;
    private readonly ?\Closure $log;
    private readonly ?string $developmentTokenFile;
    /** @var (\Closure(string): string)|null */
    private readonly ?\Closure $head;
    private readonly ?string $empty;

    /**
     * @param string|false|null $token the dashboard's token; null reads CRONWATCH_TOKEN, "" counts as unset, false serves it open
     * @param callable(string): void|null $log where the development sign-in line goes; default error_log()
     * @param string|null $developmentTokenFile where a development token is kept between requests; default in the system's temporary directory (DevelopmentToken)
     * @param callable(string): string|null $head the pages' head assets for a host that loads its own (see above)
     * @param string|null $empty the board's HTML while there are no jobs (see above)
     */
    public function __construct(
        private readonly Cronwatch $cw,
        string|false|null $token = null,
        ?string $basePath = null,
        ?string $origin = null,
        bool $trustProxy = false,
        ?callable $log = null,
        ?string $developmentTokenFile = null,
        ?callable $head = null,
        ?string $empty = null,
    ) {
        $this->optedOut = $token === false;
        $configured = null;
        if (!$this->optedOut) {
            $configured = is_string($token) && $token !== '' ? $token : Env::read('CRONWATCH_TOKEN');
        }
        $this->basePath = $basePath === null ? null : rtrim($basePath, '/');
        $this->origin = Origin::parse($origin);
        $this->trustProxy = $trustProxy;
        $this->log = $log === null ? null : \Closure::fromCallable($log);
        $this->developmentTokenFile = $developmentTokenFile;
        $this->head = $head === null ? null : \Closure::fromCallable($head);
        $this->empty = $empty;
        // A request handler cannot tell a local caller from a remote one
        // (proxies, tunnels and a server bound to every interface all look
        // alike), so development gets a token too: made on the first request,
        // and shown only in the server log.
        $this->generated = $configured === null && !$this->optedOut && Env::isDevelopment();
        $this->token = $this->generated ? null : $configured;
    }

    /** The token the dashboard asks for (the development one once made), or null when it is open or locked. */
    public function token(): ?string
    {
        return $this->token;
    }

    /** Answers the request PHP is handling now (from $_SERVER), with header() and echo. */
    public function serve(): void
    {
        $request = Request::fromGlobals();
        $this->handle($request)->send($request->method);
    }

    /** One request, answered as the SDK's routes answer it. */
    public function handle(Request $request): Response
    {
        $wantsHtml = true;
        $base = $this->basePath ?? rtrim($request->mount ?? '/cronwatch', '/');
        try {
            $path = self::stripBase($request->path, $base);
            $wantsHtml = !str_starts_with($path, '/api');
            return $this->serveRequest($request, $path, $wantsHtml, $base);
        } catch (\Throwable $error) {
            try {
                $this->cw->onError($error, 'routes');
            } catch (\Throwable) {
                // Reporting must not turn a 500 into an exception.
            }
            return $wantsHtml
                ? self::html(Html::messagePage('Something went wrong', 'The request failed and the error was reported.', $base, head: $this->head), 500)
                : self::api(['ok' => false, 'error' => 'Internal error'], 500);
        }
    }

    /** The origin a browser sees: the `origin` option, the forwarded one under trustProxy, else the request's own. */
    public function publicOrigin(Request $request): string
    {
        if ($this->origin !== null) {
            return $this->origin;
        }
        return $this->trustProxy ? self::forwardedOrigin($request) : $request->origin;
    }

    /** With trustProxy: the forwarded scheme and host when present and well formed, otherwise the request's own. */
    private static function forwardedOrigin(Request $request): string
    {
        $proto = self::firstValue($request->header('x-forwarded-proto'));
        $proto = $proto === null ? null : strtolower($proto);
        $host = self::firstValue($request->header('x-forwarded-host'));
        if ($proto === null && $host === null) {
            return $request->origin;
        }
        if ($proto !== null && $proto !== 'http' && $proto !== 'https') {
            return $request->origin;
        }
        $own = (string) parse_url($request->origin, PHP_URL_SCHEME); // phpcs:ignore WordPress.WP.AlternativeFunctions.parse_url_parse_url -- runs outside WordPress too; PHP 8.2's parse_url is consistent.
        $ownHost = substr($request->origin, strlen($own) + 3);
        return Origin::bare(($proto ?? $own) . '://' . ($host ?? $ownHost)) ?? $request->origin;
    }

    /** The first entry of a comma-separated header, trimmed, or null when there is none. */
    private static function firstValue(?string $value): ?string
    {
        if ($value === null) {
            return null;
        }
        $first = Js::trim(explode(',', $value)[0]);
        return $first === '' ? null : $first;
    }

    private static function stripBase(string $pathname, string $base): string
    {
        $path = str_starts_with($pathname, $base) ? substr($pathname, strlen($base)) : $pathname;
        if ($path === '') {
            $path = '/';
        }
        if (strlen($path) > 1 && str_ends_with($path, '/')) {
            $path = substr($path, 0, -1);
        }
        return $path;
    }

    /**
     * The line a development token is announced with, written once to the
     * server log when the token is made. `origin` is the `origin` option when
     * set, otherwise that request's public origin when its host is loopback,
     * and null for any other host: the request's host is the client's to
     * choose, so the line then leaves it out rather than point the link,
     * token and all, somewhere else. `base` is the base path without a
     * trailing slash ("" when mounted at the root).
     */
    public static function developmentSignInLine(?string $origin, string $base, string $token): string
    {
        $intro = '[cronwatch] CRONWATCH_TOKEN is not set, so this development server made a token for the dashboard. Sign in: ';
        if ($origin === null) {
            return "{$intro}{$base}/?token={$token} on this server (the first request's host is not local, so the link leaves it out)";
        }
        return "{$intro}{$origin}{$base}/?token={$token}";
    }

    /**
     * Whether an origin's host is loopback: "localhost", a name ending in
     * ".localhost", an IPv4 address in 127.0.0.0/8, or the IPv6 address ::1.
     * Only an origin that reads as one counts: a Host header is anyone's to
     * send, and one such as "evil.example/.localhost" or
     * "localhost:1@evil.example" must not put the development token in a link
     * to another host.
     */
    public static function isLoopbackOrigin(string $origin): bool
    {
        $origin = Origin::bare($origin);
        if ($origin === null) {
            return false;
        }
        $at = strpos($origin, '://');
        $authority = $at === false ? $origin : substr($origin, $at + 3);
        if (str_starts_with($authority, '[')) {
            $end = strpos($authority, ']');
            $host = $end === false ? $authority : substr($authority, 0, $end + 1);
        } else {
            $host = explode(':', $authority, 2)[0];
        }
        $host = strtolower($host);
        if ($host === 'localhost' || $host === '[::1]' || str_ends_with($host, '.localhost')) {
            return true;
        }
        if (preg_match('/^127\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/D', $host, $octets) !== 1) {
            return false;
        }
        return (int) $octets[1] <= 255 && (int) $octets[2] <= 255 && (int) $octets[3] <= 255;
    }

    private function serveRequest(Request $request, string $path, bool $wantsHtml, string $base): Response
    {
        $method = strtoupper($request->method);
        $publicOrigin = $this->publicOrigin($request);

        if ($this->generated && $this->token === null) {
            // DevelopmentToken keeps it in a file between requests. A host that
            // always gives a token (the WordPress plugin) may leave that class out.
            [$this->token, $made] = class_exists(DevelopmentToken::class)
                ? DevelopmentToken::obtain($this->developmentTokenFile, $this->basePath ?? $base)
                : [rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '='), true];
            if ($made) {
                $shown = $this->origin ?? (self::isLoopbackOrigin($publicOrigin) ? $publicOrigin : null);
                $line = self::developmentSignInLine($shown, $base, $this->token);
                $this->log !== null ? ($this->log)($line) : error_log($line); // phpcs:ignore WordPress.PHP.DevelopmentFunctions.error_log_error_log -- a development server's sign-in line; never reached in the WordPress plugin, which gives a token.
            }
        }

        // The app shell: the manifest, icons, service worker, app.js and the
        // offline page. Served to anyone, since a browser fetches some of it
        // without cookies and none of it says anything about the jobs. Under a
        // head of the host's only the icons are, as nothing else is asked for.
        if (($method === 'GET' || $method === 'HEAD') && ($this->head === null || str_starts_with($path, '/icons/'))) {
            if ($path === '/offline') {
                return self::html(Html::messagePage('You are offline', 'CronWatch shows live data from your app, so it needs a connection.', $base, head: $this->head), 200, 'no-cache');
            }
            $asset = Pwa::asset($path, $base);
            if ($asset !== null) {
                return self::shell($asset, $base);
            }
        }

        // No token outside development: fail closed.
        if ($this->token === null && !$this->optedOut) {
            return $wantsHtml
                ? self::html(Html::messagePage('CronWatch routes are locked', self::LOCKED, $base, head: $this->head), 503)
                : self::api(['ok' => false, 'error' => 'CRONWATCH_TOKEN is not set'], 503);
        }

        if ($method !== 'GET' && $method !== 'HEAD' && self::crossSite($request, $publicOrigin)) {
            return $wantsHtml
                ? self::html(Html::messagePage('Cross-site request refused', 'Changes can only be made from the dashboard itself.', $base, head: $this->head), 403)
                : self::api(['ok' => false, 'error' => 'Cross-site request refused'], 403);
        }

        $cw = $this->cw;
        $authorization = $request->header('authorization');
        $bearer = $authorization === null ? null : self::stripBearer($authorization);
        if ($this->token !== null) {
            // ?token= is only the sign-in that moves the token into a cookie.
            $query = $wantsHtml && $method === 'GET' ? $request->param('token') : null;
            $sent = self::readCookie($request, self::COOKIE);
            $secret = $cw->cronSecret;
            $cronSecretOk = $path === '/api/check' && $bearer !== null && $secret !== null && hash_equals($secret, $bearer);
            if ($bearer !== null) {
                $tokenOk = hash_equals($this->token, $bearer);
            } elseif ($query !== null) {
                $tokenOk = hash_equals($this->token, $query);
            } else {
                $tokenOk = $sent !== null && hash_equals(self::cookieValue($this->token), $sent);
            }
            if (!$cronSecretOk && !$tokenOk) {
                if ($this->generated) {
                    return $wantsHtml
                        ? self::html(Html::messagePage('Sign in', 'CRONWATCH_TOKEN is not set, so this development server made a token. The sign-in link is in the server log: open it once and this browser stays signed in.', $base, true, $this->head), 401)
                        : self::api(['ok' => false, 'error' => 'Unauthorized: CRONWATCH_TOKEN is not set, so this development server made a token; it is in the server log'], 401);
                }
                return $wantsHtml
                    ? self::html(Html::messagePage('Sign in', 'Open this page with ?token=<your CRONWATCH_TOKEN> once and it will stay signed in.', $base, true, $this->head), 401)
                    : self::api(['ok' => false, 'error' => 'Unauthorized'], 401);
            }
            if ($query !== null) {
                // Move the token from the URL into a cookie so it is not in history or logs.
                $rest = array_filter($request->params(), fn (array $pair) => $pair[0] !== 'token');
                $search = $rest === [] ? '' : '?' . implode('&', array_map(fn (array $pair) => Request::formEncode($pair[0]) . '=' . Request::formEncode($pair[1]), $rest));
                $secure = str_starts_with($publicOrigin, 'https:') ? '; Secure' : '';
                $cookie = self::COOKIE . '=' . self::cookieValue($this->token) . '; Path=' . ($base === '' ? '/' : $base) . '; HttpOnly; SameSite=Lax; Max-Age=' . self::COOKIE_MAX_AGE . $secure;
                return self::redirect($request->path . $search, ['set-cookie' => $cookie]);
            }
        }

        $redirectBack = function () use ($request, $publicOrigin, $base): Response {
            $referer = $request->header('referer') ?? '';
            return self::redirect(str_starts_with($referer, $publicOrigin . '/') ? $referer : "{$base}/");
        };
        $parts = [];
        foreach (explode('/', $path) as $part) {
            if ($part === '') {
                continue;
            }
            $decoded = Request::safeDecode($part);
            if ($decoded === null) {
                return $wantsHtml
                    ? self::html(Html::messagePage('Bad request', 'The path is not valid.', $base, head: $this->head), 400)
                    : self::api(['ok' => false, 'error' => 'Bad path'], 400);
            }
            $parts[] = $decoded;
        }

        // HTML
        if ($method === 'GET' && $path === '/') {
            $entries = $cw->jobsWithRuns(self::BOARD_PAGE_RUNS);
            $now = $cw->now();
            $runsByJob = [];
            foreach ($entries as $entry) {
                $runsByJob[$entry->job->name] = $entry->runs;
            }
            $jobs = array_map(fn (JobWithRuns $entry) => $entry->job, $entries);
            return self::html(Html::dashboardPage($jobs, $runsByJob, $now, $base, null, $this->boardLanes($entries, $now), $this->head, $this->empty));
        }
        if ($method === 'GET' && count($parts) === 2 && $parts[0] === 'jobs') {
            $job = $cw->jobSummary($parts[1]);
            if ($job === null) {
                return self::html(Html::messagePage('No such job', "{$parts[1]} is not in the store.", $base, head: $this->head), 404);
            }
            $now = $cw->now();
            // Enough runs to draw the job's week; the page lists the newest fifty.
            $limit = Timeline::weekRunsLimit($job, $now);
            $runs = $cw->runs($job->name, $limit);
            return self::html(Html::jobPage($job, $runs, $now, $base, count($runs) < $limit, $this->head));
        }
        if ($method === 'POST' && $path === '/check') {
            $cw->check();
            return $redirectBack();
        }
        if ($method === 'POST' && count($parts) === 3 && $parts[0] === 'jobs') {
            [, $name, $action] = $parts;
            if ($action === 'forget') {
                $cw->forget($name);
                return self::redirect("{$base}/");
            }
            if ($action !== 'silence' && $action !== 'unsilence') {
                return self::html(Html::messagePage('Not found', $path, $base, head: $this->head), 404);
            }
            if ($cw->jobSummary($name) === null) {
                return self::html(Html::messagePage('No such job', "{$name} is not in the store.", $base, head: $this->head), 404);
            }
            if ($action === 'silence') {
                if ($request->bodyTooLarge()) {
                    return self::html(Html::messagePage('Not silenced', 'The request was too large.', $base, head: $this->head), 413);
                }
                try {
                    $duration = self::silenceDuration(self::readBody($request)['for'] ?? null);
                } catch (\InvalidArgumentException $error) {
                    return self::html(Html::messagePage('Not silenced', $error->getMessage(), $base, head: $this->head), 400);
                }
                $cw->silence($name, $duration);
            } else {
                $cw->unsilence($name);
            }
            return $redirectBack();
        }

        // JSON API
        if ($parts !== [] && $parts[0] === 'api') {
            return $this->serveApi($request, $method, array_slice($parts, 1), $bearer);
        }

        return self::html(Html::messagePage('Not found', $path, $base, head: $this->head), 404);
    }

    /** @param list<string> $rest the path's parts after "api" */
    private function serveApi(Request $request, string $method, array $rest, ?string $bearer): Response
    {
        $cw = $this->cw;
        if ($method === 'GET' && $rest === ['jobs']) {
            return self::api(['ok' => true, 'jobs' => $cw->jobs()]);
        }
        if (count($rest) === 2 && $rest[0] === 'jobs') {
            $name = $rest[1];
            if ($method === 'GET') {
                $job = $cw->jobSummary($name);
                if ($job === null) {
                    return self::api(['ok' => false, 'error' => 'No such job'], 404);
                }
                return self::api(['ok' => true, 'job' => $job, 'runs' => $cw->runs($name, self::runsLimit($request->param('runs')))]);
            }
            if ($method === 'DELETE') {
                if ($cw->jobSummary($name) === null) {
                    return self::api(['ok' => false, 'error' => 'No such job'], 404);
                }
                $cw->forget($name);
                return self::api(['ok' => true]);
            }
        }
        if ($method === 'POST' && count($rest) === 3 && $rest[0] === 'jobs') {
            $name = $rest[1];
            if ($cw->jobSummary($name) === null) {
                return self::api(['ok' => false, 'error' => 'No such job'], 404);
            }
            if ($rest[2] === 'silence') {
                if ($request->bodyTooLarge()) {
                    return self::api(['ok' => false, 'error' => 'Request body too large'], 413);
                }
                $body = self::readBody($request);
                try {
                    $duration = self::silenceDuration(array_key_exists('for', $body) ? $body['for'] : $request->param('for'));
                } catch (\InvalidArgumentException $error) {
                    return self::api(['ok' => false, 'error' => $error->getMessage()], 400);
                }
                return self::api(['ok' => true, 'state' => $cw->silence($name, $duration)]);
            }
            if ($rest[2] === 'unsilence') {
                return self::api(['ok' => true, 'state' => $cw->unsilence($name)]);
            }
        }
        if ($rest === ['check']) {
            // A page cannot send an Authorization header cross-site, so a GET
            // may only run the check when it carries a bearer (token or cron secret).
            if ($method === 'GET' && $bearer === null) {
                return self::api(['ok' => false, 'error' => 'Use POST, or GET with an Authorization bearer'], 405, ['allow' => 'POST']);
            }
            if ($method === 'GET' || $method === 'POST') {
                return self::api(['ok' => true] + $cw->check()->toJson());
            }
        }
        if ($method === 'GET' && count($rest) === 2 && $rest[0] === 'runs') {
            $run = $cw->getRun($rest[1]);
            return $run !== null ? self::api(['ok' => true, 'run' => $run]) : self::api(['ok' => false, 'error' => 'No such run'], 404);
        }
        return self::api(['ok' => false, 'error' => 'Not found'], 404);
    }

    /**
     * The board's timeline lanes, the first BOARD_LANES jobs. The runs
     * already read for the table usually cover the last day; only a job whose
     * twenty newest runs all fall inside it (one that runs more often than
     * every hour or so) is read again, deeper.
     *
     * @param list<JobWithRuns> $entries
     * @return list<array{job: \Cronwatch\JobSummary, runs: list<\Cronwatch\Run>, complete: bool}>
     */
    private function boardLanes(array $entries, int|float $now): array
    {
        $from = $now - Timeline::BOARD_BEHIND_MS;
        $lanes = [];
        foreach (array_slice($entries, 0, Timeline::BOARD_LANES) as $entry) {
            $runs = $entry->runs;
            $short = count($runs) >= self::BOARD_PAGE_RUNS && $runs[count($runs) - 1]->startedAt > $from;
            if (!$short) {
                $lanes[] = ['job' => $entry->job, 'runs' => $runs, 'complete' => true];
                continue;
            }
            $deeper = $this->cw->runs($entry->job->name, Timeline::BOARD_RUNS);
            $lanes[] = ['job' => $entry->job, 'runs' => $deeper, 'complete' => count($deeper) < Timeline::BOARD_RUNS];
        }
        return $lanes;
    }

    /** The cookie holds a digest of the token, so a leaked cookie does not reveal the bearer token itself. */
    public static function cookieValue(string $token): string
    {
        return hash('sha256', "cronwatch-cookie:{$token}");
    }

    /** authorization.replace(/^Bearer\s+/i, ""). */
    private static function stripBearer(string $authorization): string
    {
        $out = preg_replace('/^Bearer[' . Js::WHITESPACE . ']+/iu', '', $authorization, 1);
        return $out ?? (string) preg_replace('/^Bearer[\t\n\x0B\f\r ]+/i', '', $authorization, 1);
    }

    private static function readCookie(Request $request, string $name): ?string
    {
        $header = $request->header('cookie');
        if ($header === null || $header === '') {
            return null;
        }
        foreach (explode(';', $header) as $part) {
            $pieces = explode('=', Js::trim($part));
            // A malformed escape counts as no cookie.
            if ($pieces[0] === $name) {
                return Request::safeDecode(implode('=', array_slice($pieces, 1)));
            }
        }
        return null;
    }

    /**
     * A browser attaches Origin or Sec-Fetch-Site to a cross-site form post,
     * and a page cannot forge either. Non-browser clients send neither.
     */
    private static function crossSite(Request $request, string $publicOrigin): bool
    {
        $origin = $request->header('origin');
        if ($origin !== null && $origin !== $publicOrigin) {
            return true;
        }
        $site = $request->header('sec-fetch-site');
        return $site !== null && $site !== 'same-origin' && $site !== 'none';
    }

    /**
     * Absent means one hour; a number or numeric string is milliseconds.
     * Throws InvalidArgumentException on anything else.
     */
    private static function silenceDuration(?string $value): int|float|string
    {
        if ($value === null) {
            return '1h';
        }
        $text = Js::trim($value);
        $duration = $text;
        if (preg_match('/^[0-9]+(\.[0-9]+)?$/D', $text) === 1) {
            $number = (float) $text;
            $duration = Js::isInteger($number) && abs($number) <= Js::MAX_SAFE_INTEGER ? (int) $number : $number;
        }
        Duration::parse($duration, 'silence duration');
        return $duration;
    }

    private static function runsLimit(?string $value): int
    {
        $n = $value === null || Js::trim($value) === '' ? NAN : self::jsNumber($value);
        if (!is_finite($n)) {
            return self::DEFAULT_RUNS;
        }
        $whole = $n < 0 ? ceil($n) : floor($n);
        return (int) min(self::MAX_RUNS, max(1, $whole));
    }

    /** Number(string): decimal, 0x/0o/0b, Infinity, or NaN. */
    private static function jsNumber(string $value): float
    {
        $text = Js::trim($value);
        if ($text === '') {
            return 0.0;
        }
        if (preg_match('/^[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/D', $text) === 1) {
            return (float) $text;
        }
        if ($text === 'Infinity' || $text === '+Infinity') {
            return INF;
        }
        if ($text === '-Infinity') {
            return -INF;
        }
        if (preg_match('/^0([xXoObB])([0-9a-fA-F]+)$/D', $text, $m) === 1) {
            $digits = strtolower($m[2]);
            return match (strtolower($m[1])) {
                'x' => (float) hexdec($digits),
                'o' => preg_match('/^[0-7]+$/D', $digits) === 1 ? (float) octdec($digits) : NAN,
                default => preg_match('/^[01]+$/D', $digits) === 1 ? (float) bindec($digits) : NAN,
            };
        }
        return NAN;
    }

    /**
     * The form fields or JSON object of a request, each value as String(value)
     * gives it in JavaScript. JSON is read as request.json() reads it: bytes
     * that are not UTF-8 become U+FFFD, and a leading byte order mark is dropped.
     *
     * @return array<string, string>
     */
    private static function readBody(Request $request): array
    {
        $type = strtolower($request->header('content-type') ?? '');
        try {
            if (str_contains($type, 'application/json')) {
                $text = Js::wellFormed($request->body());
                if (str_starts_with($text, "\u{FEFF}")) {
                    $text = substr($text, 3);
                }
                $data = json_decode($text, false, 512, JSON_THROW_ON_ERROR);
                if ($data instanceof \stdClass || is_array($data)) {
                    $out = [];
                    foreach (is_array($data) ? $data : get_object_vars($data) as $key => $value) {
                        $out[(string) $key] = self::jsString($value);
                    }
                    return $out;
                }
                return [];
            }
            if (str_contains($type, 'application/x-www-form-urlencoded') || str_contains($type, 'multipart/form-data')) {
                if ($request->form !== null) {
                    $out = [];
                    foreach ($request->form as $key => $value) {
                        $out[(string) $key] = self::formValue($value);
                    }
                    return $out;
                }
                if (str_contains($type, 'multipart/form-data')) {
                    return self::multipart($request->header('content-type') ?? '', $request->body());
                }
                $out = [];
                foreach (Request::parseQuery($request->body()) as [$key, $value]) {
                    $out[$key] = $value;
                }
                return $out;
            }
        } catch (\Throwable) {
            return [];
        }
        return [];
    }

    /** String(value) for a parsed JSON value. */
    private static function jsString(mixed $value): string
    {
        return match (true) {
            $value === null => 'null',
            is_array($value) => implode(',', array_map(fn ($v) => $v === null ? '' : self::jsString($v), $value)),
            $value instanceof \stdClass => '[object Object]',
            default => Js::string($value),
        };
    }

    /** String(value) for a field the server parsed: a file is "[object File]", a list its last value. */
    private static function formValue(mixed $value): string
    {
        return match (true) {
            is_string($value) => $value,
            is_array($value) => $value === [] ? '' : self::formValue($value[array_key_last($value)]),
            is_object($value) => '[object File]',
            default => Js::string($value),
        };
    }

    /**
     * multipart/form-data as request.formData() reads it: fields as text,
     * files as "[object File]". For a body PHP did not read itself.
     *
     * @return array<string, string>
     */
    private static function multipart(string $type, string $body): array
    {
        if (preg_match('/boundary=(?:"([^"]+)"|([^;\s]+))/i', $type, $m) !== 1) {
            return [];
        }
        $boundary = '--' . ($m[1] !== '' ? $m[1] : $m[2]);
        $out = [];
        foreach (array_slice(explode($boundary, $body), 1) as $part) {
            if (str_starts_with($part, '--')) {
                break;
            }
            $part = (string) preg_replace('/^\r?\n/', '', $part);
            $split = preg_split('/\r?\n\r?\n/', $part, 2);
            if ($split === false || count($split) < 2) {
                continue;
            }
            [$head, $content] = $split;
            if (preg_match('/content-disposition:[^\r\n]*\bname="([^"]*)"/i', $head, $name) !== 1) {
                continue;
            }
            $isFile = preg_match('/content-disposition:[^\r\n]*\bfilename=/i', $head) === 1;
            $out[$name[1]] = $isFile ? '[object File]' : Js::wellFormed((string) preg_replace('/\r?\n$/', '', $content));
        }
        return $out;
    }

    /** @param array<string, string> $headers */
    private static function api(mixed $body, int $status = 200, array $headers = []): Response
    {
        return new Response($status, ['content-type' => 'application/json; charset=utf-8', 'cache-control' => 'no-store'] + $headers + self::SECURITY_HEADERS, Js::stringify($body));
    }

    /** @param array<string, string> $headers */
    private static function redirect(string $location, array $headers = []): Response
    {
        return new Response(303, ['location' => $location, 'cache-control' => 'no-store'] + self::SECURITY_HEADERS + $headers);
    }

    /**
     * An app shell file. The worker may be scoped to the base (it is served
     * from there anyway); the SVGs get a CSP of their own.
     *
     * @param array{type: string, body: string, cache: string, worker: bool} $asset
     */
    private static function shell(array $asset, string $base): Response
    {
        $headers = ['content-type' => $asset['type'], 'cache-control' => $asset['cache']] + self::SECURITY_HEADERS;
        if ($asset['type'] === 'image/svg+xml') {
            $headers['content-security-policy'] = self::ASSET_CSP;
        }
        if ($asset['worker']) {
            $headers['service-worker-allowed'] = "{$base}/";
        }
        return new Response(200, $headers, $asset['body']);
    }

    private static function html(string $body, int $status = 200, string $cache = 'no-store'): Response
    {
        return new Response($status, [
            'content-type' => 'text/html; charset=utf-8',
            'cache-control' => $cache,
            'content-security-policy' => self::CSP,
            'x-frame-options' => 'DENY',
        ] + self::SECURITY_HEADERS, Js::wellFormed($body));
    }
}
