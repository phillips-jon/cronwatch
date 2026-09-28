<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\AlertType;
use Cronwatch\Js;

/**
 * Reports alerts to Honeybadger as notices, one error per job and alert
 * type (alerts/honeybadger.ts; notices, not Check-ins, a separate product).
 * API reference: https://docs.honeybadger.io/api/reporting-exceptions/
 * POST https://api.honeybadger.io/v1/notices with X-API-Key. Answers 201.
 */
final class Honeybadger implements AlertChannel
{
    private const CLASSES = [
        'missed' => 'CronWatch::Missed',
        'failed' => 'CronWatch::Failed',
        'stuck' => 'CronWatch::Stuck',
        'slow' => 'CronWatch::Slow',
        'over_budget' => 'CronWatch::OverBudget',
        'recovered' => 'CronWatch::Recovered',
    ];

    private readonly string $apiKey;
    private readonly string $url;
    private readonly ?\Closure $link;
    private readonly Http $http;

    /**
     * @param mixed $apiKey the project API key, from Project Settings
     * @param string|null $environment default "production"
     * @param string|null $endpoint another API host, "https://eu-api.honeybadger.io" say
     * @param bool $recovered also send recoveries; default false, since Honeybadger has no levels and a recovery would read as an error
     */
    public function __construct(
        mixed $apiKey,
        private readonly ?string $environment = null,
        ?string $endpoint = null,
        private readonly bool $recovered = false,
        ?callable $link = null,
        ?Http $http = null,
    ) {
        // A pasted credential often carries a stray space or newline, which a header would refuse or send.
        $this->apiKey = Shared::required($apiKey, 'Honeybadger needs an apiKey');
        $this->url = rtrim($endpoint ?? 'https://api.honeybadger.io', '/') . '/v1/notices';
        $this->link = $link === null ? null : \Closure::fromCallable($link);
        $this->http = $http ?? NativeHttp::default();
    }

    public function name(): string
    {
        return 'honeybadger';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        if ($alert->type === AlertType::RECOVERED && !$this->recovered) {
            return;
        }
        $link = Shared::link($this->link, $alert);
        $request = ['component' => 'cronwatch', 'action' => $alert->job];
        if ($link !== null) {
            $request['url'] = $link;
        }
        $about = ['job' => $alert->job, 'type' => $alert->type];
        if (Shared::present($alert->triage)) {
            $about['triage'] = $alert->triage;
        }
        $about['details'] = Alert::detailsJson($alert->details);
        $about['run'] = Shared::runSummary($alert);
        $request['context'] = $about;
        $notice = [
            'notifier' => ['name' => 'cronwatch', 'url' => 'https://cronwatch.dev'],
            'error' => [
                'class' => self::CLASSES[$alert->type] ?? null,
                'message' => Shared::cut("{$alert->title}\n{$alert->message}", 8000),
                // No code ran here; one frame naming the job keeps the notice well formed.
                'backtrace' => [['number' => '0', 'file' => "cronwatch/{$alert->job}", 'method' => $alert->type]],
                'fingerprint' => "cronwatch:{$alert->job}:{$alert->type}",
                'tags' => ['cronwatch', $alert->type],
            ],
            'request' => $request,
            'server' => ['environment_name' => $this->environment ?? 'production'],
        ];
        Shared::post($this->http, 'Honeybadger', $this->url, [
            'content-type' => 'application/json',
            'accept' => 'application/json',
            'x-api-key' => $this->apiKey,
        ], Js::stringify($notice), [$this->apiKey]);
    }
}
