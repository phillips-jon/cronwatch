<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\AlertType;
use Cronwatch\Js;

/**
 * Sends alerts to Sentry as events, one issue per job and alert type,
 * through the envelope endpoint (alerts/sentry.ts).
 * Envelopes: https://develop.sentry.dev/sdk/data-model/envelopes/
 * Event payload: https://develop.sentry.dev/sdk/data-model/event-payloads/
 * DSN and X-Sentry-Auth: https://develop.sentry.dev/sdk/foundations/transport/authentication/
 */
final class Sentry implements AlertChannel
{
    private readonly string $endpoint;
    private readonly string $publicKey;
    private readonly ?\Closure $link;
    private readonly Http $http;

    /**
     * @param mixed $dsn the project's DSN, "https://<key>@o0.ingest.sentry.io/<project>"
     * @param string|null $environment default "production"
     * @param bool $recovered also send recoveries, as info events; default true
     */
    public function __construct(
        #[\SensitiveParameter] mixed $dsn,
        private readonly ?string $environment = null,
        private readonly ?string $release = null,
        private readonly bool $recovered = true,
        ?callable $link = null,
        ?Http $http = null,
    ) {
        // A pasted credential often carries a stray space or newline, which a header would refuse or send.
        [$this->endpoint, $this->publicKey] = self::parseDsn(Shared::required($dsn, 'Sentry needs a dsn'));
        $this->link = $link === null ? null : \Closure::fromCallable($link);
        $this->http = $http ?? Transport::default();
    }

    /**
     * The envelope endpoint and public key of a DSN.
     *
     * @return array{string, string}
     * @deprecated Internal to the Sentry channel, public by accident; removed in 1.0.
     */
    public static function parseDsn(#[\SensitiveParameter] string $dsn): array
    {
        $url = Shared::url($dsn) ?? throw new \InvalidArgumentException('Sentry needs a valid dsn');
        $segments = array_values(array_filter(explode('/', $url['pathname']), fn (string $s) => $s !== ''));
        $project = array_pop($segments);
        if ($url['username'] === '' || $project === null || preg_match('/^[0-9]+$/D', $project) !== 1) {
            throw new \InvalidArgumentException('Sentry needs a dsn like https://<key>@<host>/<project>');
        }
        $prefix = $segments === [] ? '' : '/' . implode('/', $segments);
        return ["{$url['protocol']}//{$url['host']}{$prefix}/api/{$project}/envelope/", rawurldecode($url['username'])];
    }

    public function name(): string
    {
        return 'sentry';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        if ($alert->type === AlertType::RECOVERED && !$this->recovered) {
            return;
        }
        $eventId = Shared::alertId($alert);
        $link = Shared::link($this->link, $alert);
        $event = [
            'event_id' => $eventId,
            'timestamp' => $alert->at / 1000,
            'platform' => 'other',
            'level' => Shared::severity($alert->type),
            'logger' => 'cronwatch',
            'transaction' => $alert->job,
            'environment' => $this->environment ?? 'production',
        ];
        if (Shared::present($this->release)) {
            $event['release'] = $this->release;
        }
        $extra = [];
        if (Shared::present($alert->triage)) {
            $extra['triage'] = $alert->triage;
        }
        if ($link !== null) {
            $extra['link'] = $link;
        }
        $extra['details'] = Alert::detailsJson($alert->details);
        $extra['run'] = Shared::runSummary($alert);
        $event += [
            // The first line is the issue title.
            'logentry' => ['formatted' => Shared::cut("{$alert->title}\n\n{$alert->message}", 8192)],
            'fingerprint' => ['cronwatch', $alert->job, $alert->type],
            'tags' => ['job' => Shared::cut($alert->job, 199), 'type' => $alert->type],
            'extra' => $extra,
        ];
        $payload = Js::stringify($event);
        $envelope = implode("\n", [
            Js::stringify(['event_id' => $eventId]),
            Js::stringify(['type' => 'event', 'content_type' => 'application/json', 'length' => strlen($payload)]),
            $payload,
        ]) . "\n";
        Shared::post($this->http, 'Sentry', $this->endpoint, [
            'content-type' => 'application/x-sentry-envelope',
            'x-sentry-auth' => "Sentry sentry_version=7, sentry_key={$this->publicKey}, sentry_client=cronwatch",
        ], $envelope, [$this->publicKey]);
    }
}
