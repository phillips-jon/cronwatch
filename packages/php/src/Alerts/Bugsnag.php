<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\AlertType;
use Cronwatch\Js;

/**
 * Reports alerts to Bugsnag, grouped per job and alert type, through the
 * Error Reporting API, payload version 5 (alerts/bugsnag.ts).
 * API reference: https://developer.smartbear.com/bugsnag/docs/reporting-events-and-sessions
 * POST https://notify.bugsnag.com/ with Bugsnag-Api-Key.
 */
final class Bugsnag implements AlertChannel
{
    private readonly string $apiKey;
    private readonly string $url;
    private readonly \Closure $now;
    private readonly ?\Closure $link;
    private readonly Http $http;

    /**
     * @param mixed $apiKey the project's notifier API key
     * @param string|null $releaseStage default "production"
     * @param string|null $endpoint another notify endpoint, for on-premise installs; default https://notify.bugsnag.com/
     * @param bool $recovered also send recoveries, as info events; default false, since each one is an event on an error
     * @param (callable(): (int|float))|null $now the clock for the Bugsnag-Sent-At header, in epoch milliseconds; for tests
     */
    public function __construct(
        #[\SensitiveParameter] mixed $apiKey,
        private readonly ?string $releaseStage = null,
        ?string $endpoint = null,
        private readonly bool $recovered = false,
        ?callable $now = null,
        ?callable $link = null,
        ?Http $http = null,
    ) {
        // A pasted credential often carries a stray space or newline, which a header would refuse or send.
        $this->apiKey = Shared::required($apiKey, 'Bugsnag needs an apiKey');
        $this->url = $endpoint ?? 'https://notify.bugsnag.com/';
        $this->now = $now === null ? Js::nowMs(...) : \Closure::fromCallable($now);
        $this->link = $link === null ? null : \Closure::fromCallable($link);
        $this->http = $http ?? Transport::default();
    }

    public function name(): string
    {
        return 'bugsnag';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        if ($alert->type === AlertType::RECOVERED && !$this->recovered) {
            return;
        }
        $link = Shared::link($this->link, $alert);
        $about = ['job' => $alert->job, 'type' => $alert->type];
        if (Shared::present($alert->triage)) {
            $about['triage'] = $alert->triage;
        }
        if ($link !== null) {
            $about['link'] = $link;
        }
        $about['details'] = Alert::detailsJson($alert->details);
        $about['run'] = Shared::runSummary($alert);
        $payload = [
            'apiKey' => $this->apiKey,
            'payloadVersion' => '5',
            // The notifier's own version, not the SDK's; Bugsnag asks for one.
            'notifier' => ['name' => 'cronwatch', 'version' => '1.0.0', 'url' => 'https://cronwatch.dev'],
            'events' => [[
                'exceptions' => [[
                    'errorClass' => "CronWatch {$alert->type}",
                    'message' => Shared::cut("{$alert->title}\n{$alert->message}", 8000),
                    'stacktrace' => [],
                    'type' => 'nodejs',
                ]],
                'severity' => Shared::severity($alert->type),
                'unhandled' => false,
                'severityReason' => ['type' => 'handledException'],
                'context' => $alert->job,
                'groupingHash' => "cronwatch:{$alert->job}:{$alert->type}",
                'metaData' => ['cronwatch' => $about],
                'app' => ['releaseStage' => $this->releaseStage ?? 'production'],
                'device' => ['time' => Js::iso($alert->at)],
            ]],
        ];
        Shared::post($this->http, 'Bugsnag', $this->url, [
            'content-type' => 'application/json',
            'bugsnag-api-key' => $this->apiKey,
            'bugsnag-payload-version' => '5',
            'bugsnag-sent-at' => Js::iso(($this->now)()),
        ], Js::stringify($payload), [$this->apiKey]);
    }
}
