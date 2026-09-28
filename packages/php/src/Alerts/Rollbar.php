<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\AlertType;
use Cronwatch\Js;

/**
 * Reports alerts to Rollbar, one item per job and alert type (alerts/rollbar.ts).
 * API reference: https://docs.rollbar.com/reference/create-item
 * POST https://api.rollbar.com/api/1/item/ with X-Rollbar-Access-Token.
 */
final class Rollbar implements AlertChannel
{
    private const ENDPOINT = 'https://api.rollbar.com/api/1/item/';

    private readonly string $accessToken;
    private readonly ?\Closure $link;
    private readonly Http $http;

    /**
     * @param mixed $accessToken a project access token with the post_server_item scope
     * @param string|null $environment default "production"
     * @param bool $recovered also send recoveries, as info items; default true
     */
    public function __construct(
        mixed $accessToken,
        private readonly ?string $environment = null,
        private readonly bool $recovered = true,
        ?callable $link = null,
        ?Http $http = null,
    ) {
        // A pasted credential often carries a stray space or newline, which a header would refuse or send.
        $this->accessToken = Shared::required($accessToken, 'Rollbar needs an accessToken');
        $this->link = $link === null ? null : \Closure::fromCallable($link);
        $this->http = $http ?? NativeHttp::default();
    }

    public function name(): string
    {
        return 'rollbar';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        if ($alert->type === AlertType::RECOVERED && !$this->recovered) {
            return;
        }
        $link = Shared::link($this->link, $alert);
        $custom = ['job' => $alert->job, 'type' => $alert->type];
        if (Shared::present($alert->triage)) {
            $custom['triage'] = $alert->triage;
        }
        if ($link !== null) {
            $custom['link'] = $link;
        }
        $custom['details'] = Alert::detailsJson($alert->details);
        $custom['run'] = Shared::runSummary($alert);
        $item = [
            'data' => [
                'environment' => Shared::cut($this->environment ?? 'production', 255),
                'level' => Shared::severity($alert->type),
                'timestamp' => Js::floor($alert->at / 1000),
                'title' => Shared::cut($alert->title, 255),
                // Rollbar hashes a fingerprint longer than 40 characters itself.
                'fingerprint' => "cronwatch:{$alert->job}:{$alert->type}",
                'uuid' => Shared::asUuid(Shared::alertId($alert)),
                'body' => ['message' => ['body' => $alert->message]],
                'custom' => $custom,
                'notifier' => ['name' => 'cronwatch'],
            ],
        ];
        Shared::post($this->http, 'Rollbar', self::ENDPOINT, [
            'content-type' => 'application/json',
            'x-rollbar-access-token' => $this->accessToken,
        ], Js::stringify($item), [$this->accessToken]);
    }
}
