<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\Js;

/**
 * Posts alerts to the Datadog event stream, aggregated per job and alert
 * type, through the Events API v1 (alerts/datadog.ts).
 * API reference: https://docs.datadoghq.com/api/latest/events/ (Post an event)
 * POST https://api.<site>/api/v1/events with DD-API-KEY. Answers 202.
 */
final class Datadog implements AlertChannel
{
    private const ALERT_TYPE = [
        'missed' => 'error',
        'failed' => 'error',
        'stuck' => 'error',
        'slow' => 'warning',
        'over_budget' => 'warning',
        'recovered' => 'success',
    ];

    private readonly string $apiKey;
    private readonly string $url;
    private readonly ?\Closure $link;
    private readonly Http $http;

    /**
     * @param mixed $apiKey an API key (not an application key)
     * @param string|null $site "datadoghq.com" (the default), "datadoghq.eu", "us3.datadoghq.com", "us5.datadoghq.com",
     *        "ap1.datadoghq.com" or "ddog-gov.com"
     * @param list<string> $tags extra tags, "env:prod" say; every event also has cronwatch, job:<name> and alert:<type>
     * @param string|null $host associates the event with a host and its tags
     */
    public function __construct(
        mixed $apiKey,
        ?string $site = null,
        private readonly array $tags = [],
        private readonly ?string $host = null,
        ?callable $link = null,
        ?Http $http = null,
    ) {
        // A pasted credential often carries a stray space or newline, which a header would refuse or send.
        $this->apiKey = Shared::required($apiKey, 'Datadog needs an apiKey');
        $site = (string) preg_replace(['/^https?:\/\//', '/^(api|app)\./', '/\/+$/'], '', $site ?? 'datadoghq.com');
        if (preg_match('/^[a-z0-9.-]+$/Di', $site) !== 1) {
            throw new \InvalidArgumentException('Datadog needs a site like datadoghq.com');
        }
        $this->url = "https://api.{$site}/api/v1/events";
        $this->link = $link === null ? null : \Closure::fromCallable($link);
        $this->http = $http ?? NativeHttp::default();
    }

    public function name(): string
    {
        return 'datadog';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $link = Shared::link($this->link, $alert);
        $event = [
            'title' => Shared::cut($alert->title, 500),
            'text' => Shared::cut(Shared::plainText($alert, $link), 4000),
            'alert_type' => self::ALERT_TYPE[$alert->type] ?? null,
            'aggregation_key' => self::aggregationKey($alert),
            'date_happened' => Js::floor($alert->at / 1000),
            'priority' => 'normal',
            'tags' => ['cronwatch', "job:{$alert->job}", "alert:{$alert->type}", ...array_values($this->tags)],
        ];
        if (Shared::present($this->host)) {
            $event['host'] = $this->host;
        }
        Shared::post($this->http, 'Datadog', $this->url, [
            'content-type' => 'application/json',
            'accept' => 'application/json',
            'dd-api-key' => $this->apiKey,
        ], Js::stringify($event), [$this->apiKey]);
    }

    /** "cronwatch:<job>:<type>", or a hash of it when that passes Datadog's 100 characters. */
    private static function aggregationKey(Alert $alert): string
    {
        $key = "cronwatch:{$alert->job}:{$alert->type}";
        return Js::length16($key) <= 100 ? $key : 'cronwatch:' . substr(Shared::sha256Hex($key), 0, 40);
    }
}
