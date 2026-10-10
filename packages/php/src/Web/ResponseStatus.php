<?php

declare(strict_types=1);

namespace Cronwatch\Web;

/**
 * HTTP responses a job hands back. The SDK fails a run whose function
 * returns a fetch Response with a status of 400 or more; PHP has no one
 * response type, so the common ones count, read by duck typing so that no
 * framework or PSR package is needed:
 *
 * - Web\Response, this package's own;
 * - anything with a getStatusCode() answering a whole number from 100 to
 *   599: PSR-7 responses (Guzzle's, Nyholm's, Laminas'), Symfony's and
 *   Laravel's HttpFoundation responses, Symfony's HttpClient responses;
 * - Laravel's HTTP client response (status() and reason());
 * - a plain array with a whole-number "status" from 100 to 599 and no key
 *   but "status", "headers", and "body" (what a handler may answer with).
 *
 * The reason is the one the response carries (a PSR-7 reason phrase,
 * HttpFoundation's status text), else "", as a fetch Response made without
 * a statusText has none.
 *
 * @internal
 */
final class ResponseStatus
{
    /** The keys a response array may have. */
    public const ARRAY_KEYS = ['status', 'headers', 'body'];

    /** @return array{int, string}|null [status, reason] for a response, null for anything else */
    public static function of(mixed $value): ?array
    {
        if ($value instanceof Response) {
            return [$value->status, ''];
        }
        if (is_array($value)) {
            return self::isArrayResponse($value) ? [$value['status'], ''] : null;
        }
        if (!is_object($value) || $value instanceof \Throwable || $value instanceof \Closure) {
            return null;
        }
        try {
            if (is_a($value, 'Illuminate\Http\Client\Response') && method_exists($value, 'status')) {
                $status = $value->status();
                $reason = method_exists($value, 'reason') ? $value->reason() : '';
                return self::inRange($status) ? [$status, is_string($reason) ? $reason : ''] : null;
            }
            if (!method_exists($value, 'getStatusCode')) {
                return null;
            }
            $status = $value->getStatusCode();
            if (!self::inRange($status)) {
                return null;
            }
            return [$status, self::reason($value)];
        } catch (\Throwable) {
            // A response that cannot say its status (an HTTP client's that failed to connect) is not one.
            return null;
        }
    }

    /** @param array<array-key, mixed> $value */
    public static function isArrayResponse(array $value): bool
    {
        if (!array_key_exists('status', $value) || array_diff(array_map('strval', array_keys($value)), self::ARRAY_KEYS) !== []) {
            return false;
        }
        return self::inRange($value['status']);
    }

    private static function inRange(mixed $status): bool
    {
        return is_int($status) && $status >= 100 && $status <= 599;
    }

    private static function reason(object $value): string
    {
        if (method_exists($value, 'getReasonPhrase')) {
            $reason = $value->getReasonPhrase();
            return is_string($reason) ? $reason : '';
        }
        if (is_a($value, 'Symfony\Component\HttpFoundation\Response')) {
            // HttpFoundation keeps the status text it was made with, protected.
            $text = (fn () => $this->statusText ?? '')->call($value);
            return is_string($text) ? $text : '';
        }
        return '';
    }
}
