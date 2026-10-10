<?php

declare(strict_types=1);

namespace Cronwatch\Web;

use Cronwatch\Job\Handler;
use Psr\Http\Message\ResponseFactoryInterface;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Message\StreamFactoryInterface;
use Psr\Http\Server\RequestHandlerInterface;

/**
 * A job's handler() as a PSR-15 request handler, for Slim, Mezzio, and
 * anything that speaks PSR-7:
 *
 *     $factory = new Nyholm\Psr7\Factory\Psr17Factory();
 *     $cron = new Cronwatch\Web\PsrJobHandler($nightly->handler($fn), $factory, $factory);
 *     $app->post('/cron/nightly', fn ($request) => $cron->handle($request));
 *
 * The function gets the PSR-7 request. Its answer is written with the
 * PSR-17 factories given; a PSR-7 response the function returned is passed
 * on as it is, and an HttpFoundation one is copied into PSR-7.
 */
final class PsrJobHandler implements RequestHandlerInterface
{
    public function __construct(
        private readonly Handler $handler,
        private readonly ResponseFactoryInterface $responses,
        private readonly StreamFactoryInterface $streams,
    ) {
    }

    public function handle(ServerRequestInterface $request): ResponseInterface
    {
        $answer = $this->handler->respond($request);
        if ($answer instanceof ResponseInterface) {
            return $answer;
        }
        if (Handler::isOwn($answer)) {
            $response = Handler::own($answer)->toPsr($this->responses, $this->streams);
            \assert($response instanceof ResponseInterface);
            return $response;
        }
        if (is_object($answer) && is_a($answer, HttpFoundation::RESPONSE)) {
            $response = $this->responses->createResponse($answer->getStatusCode());
            foreach ($answer->headers->allPreserveCaseWithoutCookies() as $name => $values) {
                $response = $response->withHeader($name, $values);
            }
            foreach ($answer->headers->getCookies() as $cookie) {
                $response = $response->withAddedHeader('Set-Cookie', (string) $cookie);
            }
            return $response->withBody($this->streams->createStream((string) $answer->getContent()));
        }
        throw new \TypeError(get_debug_type($answer) . ' is a response a PSR-15 handler cannot answer with; return a PSR-7 response, a Cronwatch\Web\Response, or an array response');
    }
}
