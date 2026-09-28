<?php

declare(strict_types=1);

namespace Cronwatch\Web;

use Psr\Http\Message\ResponseFactoryInterface;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Message\StreamFactoryInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;

/**
 * The dashboard as PSR-15 middleware: a request under the base path
 * ("/cronwatch" unless given) is answered by the dashboard, anything else
 * goes on to the next handler. For an app with psr/http-server-middleware:
 *
 *     $factory = new Nyholm\Psr7\Factory\Psr17Factory();
 *     $app->add(new Cronwatch\Web\PsrMiddleware($cw->routes(basePath: '/ops/cron'), $factory, $factory, '/ops/cron'));
 */
final class PsrMiddleware implements MiddlewareInterface
{
    private readonly string $base;

    public function __construct(
        private readonly Dashboard $dashboard,
        private readonly ResponseFactoryInterface $responses,
        private readonly StreamFactoryInterface $streams,
        string $basePath = '/cronwatch',
    ) {
        $this->base = rtrim($basePath, '/');
    }

    public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
    {
        $path = Request::normalizePath($request->getUri()->getPath());
        if ($this->base !== '' && $path !== $this->base && !str_starts_with($path, $this->base . '/')) {
            return $handler->handle($request);
        }
        $response = $this->dashboard->handle(Request::fromPsr($request))->toPsr($this->responses, $this->streams);
        \assert($response instanceof ResponseInterface);
        return $response;
    }
}
