<?php

declare(strict_types=1);

namespace Cronwatch\Job;

use Cronwatch\Cronwatch;
use Cronwatch\Env;
use Cronwatch\JobDefinition;
use Cronwatch\Js;
use Cronwatch\RunStatus;
use Cronwatch\Web\HttpFoundation;
use Cronwatch\Web\Request;
use Cronwatch\Web\Response;
use Cronwatch\Web\ResponseStatus;

/**
 * $job->handler(): the SDK's fetch-style job handler, for a cron that calls
 * a URL (a platform's cron, Cloud Scheduler, a crontab line running curl).
 * Each request carrying the cron secret runs the function as a recorded run
 * and is answered with how it went:
 *
 *     $cron = $cw->job('nightly-report', ['schedule' => '0 2 * * *'])
 *         ->handler(fn (JobContext $job, $request) => build_report($job));
 *
 *     $cron->serve();                                        // a bare script, from the superglobals
 *     Route::post('/cron/nightly', $cron->laravel());        // Laravel
 *     return $cron($request);                                // a Symfony controller (or Laravel's)
 *     new Cronwatch\Web\PsrJobHandler($cron, $f, $f);        // PSR-15 (Slim, Mezzio)
 *
 * The caller must send `Authorization: Bearer <secret>`, compared in
 * constant time. The secret is the handler's own `secret:`, else the
 * client's cronSecret (CRON_SECRET by default); "" (the default) counts as
 * unset, and `secret: null` (or a client made with `cronSecret: null`) lets
 * anyone run the job. `false` does what null does, deprecated since 1.0 and
 * removed in 2.0 (in 0.x, null meant the client's secret). With no secret at all the handler answers 503 unless the
 * environment is development (see Env), and reports it once to onError as
 * "handler". A wrong or missing bearer is 401.
 *
 * The answer is JSON, {"ok", "job", "run", "status", "durationMs"}, 200 when
 * the run was ok and 500 when it failed, with the error's first line as
 * "error" only for a caller who sent the secret. A function that returns a
 * response (any ResponseStatus reads) is answered with it instead, and a
 * status of 400 or more fails the run, as it does for run().
 */
final class Handler
{
    public const NO_SECRET = 'CRON_SECRET is not set, so this job will not run for an unauthenticated request. Set it, or pass secret: null to handler() to allow anyone.';
    public const HEADERS = ['content-type' => 'application/json; charset=utf-8', 'cache-control' => 'no-store'];

    /** The secret a request must carry, or null when none is required. */
    public readonly ?string $secret;
    public readonly string $job;
    private readonly bool $optedOut;
    private readonly \Closure $fn;

    /** @internal Made by JobHandle::handler(). */
    public function __construct(
        private readonly Cronwatch $client,
        private readonly JobDefinition $definition,
        callable $fn,
        string|false|null $secret = '',
    ) {
        $this->fn = \Closure::fromCallable($fn);
        $this->job = (string) $definition->get('name');
        $off = $secret === null || $secret === false;
        $this->secret = $off ? null : ($secret !== '' ? $secret : $client->cronSecret);
        $this->optedOut = $off || ($secret === '' && $client->secretOptOut);
    }

    // ------------------------------------------------------------ the core

    /**
     * Runs the job for a request of any kind and returns the answer: a
     * Web\Response, or the response the function returned.
     */
    public function respond(mixed $request): mixed
    {
        $refused = $this->refusal($request);
        if ($refused !== null) {
            return $refused;
        }
        $fn = $this->fn;
        $outcome = $this->client->executeOutcome($this->definition, 'handler', fn (JobContext $job) => $fn($job, $request));
        if (ResponseStatus::of($outcome->result) !== null) {
            return $outcome->result;
        }
        $run = $outcome->run;
        $body = [
            'ok' => $run->status === RunStatus::OK,
            'job' => $this->job,
            'run' => $run->id,
            'status' => $run->status,
            'durationMs' => $run->durationMs,
        ];
        // Error text only goes to a caller who proved they hold the secret.
        if ($this->secret !== null && $run->error !== null && $run->error !== '') {
            $body['error'] = explode("\n", $run->error)[0];
        }
        return self::json($body, $run->status === RunStatus::OK ? 200 : 500);
    }

    /** The answer for a request that may not run the job, or null when it may. */
    private function refusal(mixed $request): ?Response
    {
        if ($this->secret === null && !$this->optedOut && !Env::isDevelopment()) {
            $this->client->warnNoSecret();
            return self::json(['ok' => false, 'error' => self::NO_SECRET], 503);
        }
        if ($this->secret !== null && !hash_equals("Bearer {$this->secret}", self::authorization($request))) {
            return self::json(['ok' => false, 'error' => 'Unauthorized'], 401);
        }
        return null;
    }

    /** @param array<string, mixed> $body */
    private static function json(array $body, int $status): Response
    {
        return new Response($status, self::HEADERS, Js::stringify($body));
    }

    /**
     * The Authorization header of a request of any kind: a Web\Request, a
     * Symfony or Laravel request, a PSR-7 request, or an array of server
     * variables ($_SERVER) or with a "headers" array.
     */
    public static function authorization(mixed $request): string
    {
        if ($request instanceof Request) {
            return $request->header('authorization') ?? '';
        }
        if (is_array($request)) {
            if (isset($request['headers']) && is_array($request['headers'])) {
                foreach ($request['headers'] as $name => $value) {
                    if (strtolower((string) $name) === 'authorization') {
                        return self::text($value);
                    }
                }
                return '';
            }
            return self::text($request['HTTP_AUTHORIZATION'] ?? $request['REDIRECT_HTTP_AUTHORIZATION'] ?? '');
        }
        if (!is_object($request)) {
            return '';
        }
        if (isset($request->headers) && is_object($request->headers) && method_exists($request->headers, 'get')) {
            return self::text($request->headers->get('authorization'));
        }
        if (method_exists($request, 'getHeaderLine')) {
            return self::text($request->getHeaderLine('authorization'));
        }
        return '';
    }

    private static function text(mixed $value): string
    {
        if (is_array($value)) {
            return self::text($value[0] ?? '');
        }
        return is_scalar($value) ? (string) $value : '';
    }

    // ------------------------------------------------------------ adapters

    /**
     * Answers a request in its own kind: an HttpFoundation response for a
     * Symfony request (Laravel's own for a Laravel request), and a
     * Web\Response otherwise (psr15() answers PSR-7 with PSR-7). A response
     * the function returned is passed on as it is, but for an array, which
     * is made into the request's kind.
     */
    public function __invoke(mixed $request): mixed
    {
        $answer = $this->respond($request);
        if (HttpFoundation::isRequest($request)) {
            return self::isOwn($answer) ? HttpFoundation::toResponse(self::own($answer), HttpFoundation::isLaravel($request)) : $answer;
        }
        return self::isOwn($answer) ? self::own($answer) : $answer;
    }

    /** A Laravel route action: Route::post('/cron/nightly', $handler->laravel()). */
    public function laravel(): \Closure
    {
        return fn (\Illuminate\Http\Request $request) => $this($request);
    }

    /** A Symfony controller callable, for a route defined in PHP. */
    public function symfony(): \Closure
    {
        return fn (\Symfony\Component\HttpFoundation\Request $request) => $this($request);
    }

    /**
     * Answers the request PHP is serving, from the superglobals, with
     * header() and echo: for a bare script such as public/cron/nightly.php.
     * The function gets a Web\Request.
     */
    public function serve(): void
    {
        $request = Request::fromGlobals();
        self::send($this->respond($request), $request->method);
    }

    /**
     * Writes an answer of any kind this handler returns: a Web\Response, an
     * array response, an HttpFoundation response or a PSR-7 response.
     */
    public static function send(mixed $answer, string $method = 'GET'): void
    {
        if (self::isOwn($answer)) {
            self::own($answer)->send($method);
            return;
        }
        if (is_object($answer) && is_a($answer, 'Symfony\Component\HttpFoundation\Response')) {
            $answer->send();
            return;
        }
        if (is_object($answer) && method_exists($answer, 'getStatusCode') && method_exists($answer, 'getHeaders') && method_exists($answer, 'getBody')) {
            $headers = [];
            foreach ($answer->getHeaders() as $name => $values) {
                $headers[strtolower((string) $name)] = implode(', ', (array) $values);
            }
            $body = $answer->getBody();
            if ($body->isSeekable()) {
                $body->rewind();
            }
            (new Response($answer->getStatusCode(), $headers, (string) $body->getContents()))->send($method);
            return;
        }
        throw new \TypeError(get_debug_type($answer) . ' is a response this handler cannot send; return a Cronwatch\Web\Response, an array response, an HttpFoundation or a PSR-7 response');
    }

    /** Whether an answer is this package's own kind: a Web\Response or an array response. */
    public static function isOwn(mixed $answer): bool
    {
        return $answer instanceof Response || (is_array($answer) && ResponseStatus::isArrayResponse($answer));
    }

    /** A Web\Response, or an array response made into one. */
    public static function own(Response|array $answer): Response
    {
        if ($answer instanceof Response) {
            return $answer;
        }
        $headers = [];
        foreach ((array) ($answer['headers'] ?? []) as $name => $value) {
            $headers[strtolower((string) $name)] = is_array($value) ? implode(', ', array_map('strval', $value)) : (string) $value;
        }
        $body = $answer['body'] ?? '';
        return new Response($answer['status'], $headers, is_string($body) ? $body : Js::stringify($body));
    }
}
