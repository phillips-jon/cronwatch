<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;

/**
 * Sends alerts as email through Mailgun (alerts/mailgun.ts).
 * API reference: https://documentation.mailgun.com/docs/mailgun/api-reference/send/mailgun/messages/post-v3--domain-name--messages
 * POST https://api.mailgun.net/v3/<domain>/messages (api.eu.mailgun.net for
 * the EU region), form encoded, with basic auth "api:<key>".
 */
final class Mailgun implements AlertChannel
{
    private readonly string $apiKey;
    /** @var list<string> */
    private readonly array $to;
    private readonly string $url;
    private readonly ?\Closure $link;
    private readonly Http $http;

    /**
     * @param mixed $apiKey a sending or account API key
     * @param string $domain the sending domain, "mg.example.com"
     * @param string|list<string> $to
     * @param string|null $region "eu" for a domain in the EU region; default "us"
     */
    public function __construct(
        mixed $apiKey,
        string $domain,
        private readonly string $from,
        string|array $to,
        ?string $region = null,
        private readonly ?string $subjectPrefix = null,
        ?callable $link = null,
        ?Http $http = null,
    ) {
        // A pasted credential often carries a stray space or newline, which a header would refuse or send.
        $this->apiKey = Shared::required($apiKey, 'Mailgun needs an apiKey');
        if ($domain === '') {
            throw new \InvalidArgumentException('Mailgun needs a domain');
        }
        $this->to = Email::recipients('Mailgun', $from, $to);
        $host = $region === 'eu' ? 'https://api.eu.mailgun.net' : 'https://api.mailgun.net';
        $this->url = "{$host}/v3/" . Shared::encodeUriComponent($domain) . '/messages';
        $this->link = $link === null ? null : \Closure::fromCallable($link);
        $this->http = $http ?? NativeHttp::default();
    }

    public function name(): string
    {
        return 'mailgun';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $email = Email::compose($alert, $this->from, $this->to, $this->subjectPrefix, $this->link);
        $pairs = [['from', $email->from]];
        foreach ($email->to as $address) {
            $pairs[] = ['to', $address];
        }
        array_push($pairs, ['subject', $email->subject], ['text', $email->text], ['html', $email->html], ['o:tag', 'cronwatch']);
        Shared::post($this->http, 'Mailgun', $this->url, [
            'content-type' => 'application/x-www-form-urlencoded',
            'authorization' => Shared::basicAuth('api', $this->apiKey),
        ], Shared::form($pairs), [$this->apiKey]);
    }
}
