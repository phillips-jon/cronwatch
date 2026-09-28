<?php

declare(strict_types=1);

namespace Cronwatch\Tests\Support;

use Cronwatch\Alerts\Http;
use Cronwatch\Alerts\HttpResponse;

/** Stands in for the network: answers every request with `answer(url, body, headers)`, keeping each. */
final class FakeHttp implements Http
{
    /** @var list<array{url: string, body: string, headers: array<string, string>, timeoutMs: int}> */
    public array $requests = [];
    private readonly \Closure $answer;

    /** @param (\Closure(string, string, array<string, string>): array{int, string})|null $answer */
    public function __construct(int $status = 200, string $body = '', ?\Closure $answer = null)
    {
        $this->answer = $answer ?? fn () => [$status, $body];
    }

    public function post(string $url, string $body, array $headers, int $timeoutMs = self::TIMEOUT_MS): HttpResponse
    {
        $this->requests[] = ['url' => $url, 'body' => $body, 'headers' => $headers, 'timeoutMs' => $timeoutMs];
        [$status, $text] = ($this->answer)($url, $body, $headers);
        return new HttpResponse($status, $text);
    }

    /** The form fields of a form encoded body. */
    public static function form(string $body): array
    {
        $fields = [];
        foreach (explode('&', $body) as $pair) {
            [$name, $value] = array_pad(explode('=', $pair, 2), 2, '');
            $fields[urldecode($name)][] = urldecode($value);
        }
        return $fields;
    }
}
