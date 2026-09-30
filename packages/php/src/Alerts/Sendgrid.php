<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\Js;

/**
 * Sends alerts as email through SendGrid (alerts/sendgrid.ts).
 * API reference: https://www.twilio.com/docs/sendgrid/api-reference/mail-send/mail-send
 * POST https://api.sendgrid.com/v3/mail/send (api.eu.sendgrid.com for EU
 * subusers) with a bearer API key. Answers 202.
 */
final class Sendgrid implements AlertChannel
{
    private readonly string $apiKey;
    /** @var list<string> */
    private readonly array $to;
    private readonly string $url;
    private readonly ?\Closure $link;
    private readonly Http $http;

    /**
     * @param mixed $apiKey an API key with Mail Send access
     * @param string|list<string> $to
     * @param string|null $region "eu" for an EU regional subuser; default "us"
     */
    public function __construct(
        #[\SensitiveParameter] mixed $apiKey,
        private readonly string $from,
        string|array $to,
        ?string $region = null,
        private readonly ?string $subjectPrefix = null,
        ?callable $link = null,
        ?Http $http = null,
    ) {
        // A pasted credential often carries a stray space or newline, which a header would refuse or send.
        $this->apiKey = Shared::required($apiKey, 'Sendgrid needs an apiKey');
        $this->to = Email::recipients('Sendgrid', $from, $to);
        $this->url = $region === 'eu' ? 'https://api.eu.sendgrid.com/v3/mail/send' : 'https://api.sendgrid.com/v3/mail/send';
        $this->link = $link === null ? null : \Closure::fromCallable($link);
        $this->http = $http ?? Transport::default();
    }

    public function name(): string
    {
        return 'sendgrid';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $email = Email::compose($alert, $this->from, $this->to, $this->subjectPrefix, $this->link);
        Shared::post($this->http, 'SendGrid', $this->url, [
            'content-type' => 'application/json',
            'authorization' => "Bearer {$this->apiKey}",
        ], Js::stringify([
            'personalizations' => [['to' => array_map(Email::parseAddress(...), $email->to)]],
            'from' => Email::parseAddress($email->from),
            'subject' => $email->subject,
            // text/plain must come before text/html.
            'content' => [
                ['type' => 'text/plain', 'value' => $email->text],
                ['type' => 'text/html', 'value' => $email->html],
            ],
            'categories' => ['cronwatch'],
        ]), [$this->apiKey]);
    }
}
