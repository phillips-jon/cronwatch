<?php

declare(strict_types=1);

namespace Cronwatch\Web;

/**
 * Symfony's HttpFoundation, which Laravel's requests and responses extend,
 * read and written for the dashboard and a job's handler(). Duck typed by
 * class name, so nothing here loads Symfony until a Symfony (or Laravel)
 * request is handed to it.
 */
final class HttpFoundation
{
    public const REQUEST = 'Symfony\Component\HttpFoundation\Request';
    public const RESPONSE = 'Symfony\Component\HttpFoundation\Response';

    public static function isRequest(mixed $request): bool
    {
        return is_object($request) && is_a($request, self::REQUEST);
    }

    public static function isLaravel(mixed $request): bool
    {
        return is_object($request) && is_a($request, 'Illuminate\Http\Request');
    }

    /**
     * The dashboard's Request from an HttpFoundation request, read as the SDK
     * reads a fetch Request: the path as the browser sent it (the request
     * target, base URL included), the raw query, every header, the body, and
     * the origin as the framework sees it (so its trusted proxies apply).
     */
    public static function toRequest(object $request): Request
    {
        $target = (string) $request->server->get('REQUEST_URI', '');
        if ($target === '' || $target[0] !== '/') {
            // A request made by hand (or an absolute-form target): the URI Symfony composed.
            $target = (string) $request->getRequestUri();
            if (preg_match('#^[A-Za-z][A-Za-z0-9+.\-]*://[^/?\#]*(.*)$#Ds', $target, $m) === 1) {
                $target = $m[1];
            }
        }
        $target = explode('#', $target, 2)[0];
        [$path, $query] = array_pad(explode('?', $target, 2), 2, '');
        if ($query === '' && is_string($request->server->get('QUERY_STRING')) && !str_contains($target, '?')) {
            $query = (string) $request->server->get('QUERY_STRING');
        }
        $headers = [];
        foreach ($request->headers->all() as $name => $values) {
            $name = strtolower((string) $name);
            $headers[$name] = implode($name === 'cookie' ? '; ' : ', ', (array) $values);
        }
        $form = null;
        if (str_contains(strtolower($headers['content-type'] ?? ''), 'multipart/form-data')) {
            $form = $request->request->all();
            foreach (array_keys($request->files->all()) as $name) {
                $form[$name] = new \SplFileInfo((string) $name);
            }
        }
        return new Request(
            (string) $request->getMethod(),
            Request::normalizePath($path),
            $query,
            $headers,
            // As a string, as the framework reads it for any controller (a resource
            // read would stop anything later asking for the string); a body
            // past Request::MAX_BODY is told by its Content-Length before this.
            static fn (): string => (string) $request->getContent(),
            Request::originOf((string) $request->getScheme(), (string) $request->getHttpHost()),
            null,
            $form,
        );
    }

    /**
     * An HttpFoundation response with the dashboard's (or a handler's) status,
     * headers and body: Laravel's Illuminate\Http\Response when `laravel`,
     * so Laravel middleware that call its helpers work, else Symfony's.
     */
    public static function toResponse(Response $response, bool $laravel = false): object
    {
        $class = $laravel && class_exists('Illuminate\Http\Response') ? 'Illuminate\Http\Response' : self::RESPONSE;
        $out = new $class($response->body, $response->status);
        foreach ($response->headers as $name => $value) {
            $out->headers->set($name, $value);
        }
        if (!isset($response->headers['cache-control'])) {
            // HttpFoundation would add its own ("no-cache, private"); the SDK's answer has none.
            $out->headers->remove('cache-control');
        }
        return $out;
    }
}
