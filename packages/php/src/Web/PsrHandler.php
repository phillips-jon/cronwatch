<?php

declare(strict_types=1);

namespace Cronwatch\Web;

use Psr\Http\Message\ResponseFactoryInterface;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Message\StreamFactoryInterface;
use Psr\Http\Server\RequestHandlerInterface;

/**
 * The dashboard as a PSR-15 request handler, for an app with
 * psr/http-server-handler and a PSR-17 factory (nyholm/psr7, guzzlehttp/psr7,
 * laminas-diactoros, slim/psr7). Route the dashboard's paths to it:
 *
 *     $factory = new Nyholm\Psr7\Factory\Psr17Factory();
 *     $handler = new Cronwatch\Web\PsrHandler($cw->routes(), $factory, $factory);
 *     $app->any('/cronwatch[/{path:.*}]', fn ($request) => $handler->handle($request));   // Slim
 *
 * This class and PsrMiddleware are the only ones that need the PSR
 * interfaces; nothing else in the package loads them.
 */
final class PsrHandler implements RequestHandlerInterface
{
    public function __construct(
        private readonly Dashboard $dashboard,
        private readonly ResponseFactoryInterface $responses,
        private readonly StreamFactoryInterface $streams,
    ) {
    }

    public function handle(ServerRequestInterface $request): ResponseInterface
    {
        $response = $this->dashboard->handle(Request::fromPsr($request))->toPsr($this->responses, $this->streams);
        \assert($response instanceof ResponseInterface);
        return $response;
    }
}
