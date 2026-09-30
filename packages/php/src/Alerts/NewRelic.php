<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\Js;

/**
 * Records alerts as New Relic custom events through the Event API (alerts/newrelic.ts).
 * API reference: https://docs.newrelic.com/docs/data-apis/ingest-apis/event-api/introduction-event-api/
 * POST https://insights-collector.newrelic.com/v1/accounts/<id>/events
 * (insights-collector.eu01.nr-data.net for EU accounts) with Api-Key.
 * Each alert is one custom event of type CronWatchAlert, queryable with NRQL:
 * SELECT * FROM CronWatchAlert WHERE job = 'nightly'.
 */
final class NewRelic implements AlertChannel
{
    private readonly string $apiKey;
    private readonly string $url;
    private readonly string $eventType;
    private readonly ?\Closure $link;
    private readonly Http $http;

    /**
     * @param string|int $accountId the account id, the number in your New Relic URLs
     * @param mixed $apiKey a license key (INGEST - LICENSE)
     * @param string|null $region "eu" for an account in the EU data center; default "us"
     * @param string|null $eventType default "CronWatchAlert"
     */
    public function __construct(
        string|int|float|null $accountId,
        #[\SensitiveParameter] mixed $apiKey,
        ?string $region = null,
        ?string $eventType = null,
        ?callable $link = null,
        ?Http $http = null,
    ) {
        // A pasted credential often carries a stray space or newline, which a header would refuse or send.
        $this->apiKey = Shared::required($apiKey, 'NewRelic needs an apiKey');
        $account = $accountId === null ? '' : Js::string($accountId);
        if (preg_match('/^[0-9]+$/D', $account) !== 1) {
            throw new \InvalidArgumentException('NewRelic needs a numeric accountId');
        }
        $host = $region === 'eu' ? 'https://insights-collector.eu01.nr-data.net' : 'https://insights-collector.newrelic.com';
        $this->url = "{$host}/v1/accounts/{$account}/events";
        $this->eventType = $eventType ?? 'CronWatchAlert';
        $this->link = $link === null ? null : \Closure::fromCallable($link);
        $this->http = $http ?? Transport::default();
    }

    public function name(): string
    {
        return 'newrelic';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $link = Shared::link($this->link, $alert);
        $run = $alert->run;
        // Flat attributes only, strings under 4096 characters.
        $event = [
            'eventType' => $this->eventType,
            'timestamp' => $alert->at,
            'job' => Shared::cut($alert->job, 4095),
            'alertType' => $alert->type,
            'severity' => Shared::severity($alert->type),
            'title' => Shared::cut($alert->title, 4095),
            'message' => Shared::cut($alert->message, 4095),
        ];
        if (Shared::present($alert->triage)) {
            $event['triage'] = Shared::cut((string) $alert->triage, 4095);
        }
        if ($link !== null) {
            $event['link'] = Shared::cut($link, 4095);
        }
        if ($run !== null) {
            $event['runId'] = $run->id;
            $event['runStatus'] = $run->status;
            if ($run->durationMs !== null) {
                $event['durationMs'] = $run->durationMs;
            }
        }
        Shared::post($this->http, 'New Relic', $this->url, [
            'content-type' => 'application/json',
            'api-key' => $this->apiKey,
        ], Js::stringify([$event]), [$this->apiKey]);
    }
}
