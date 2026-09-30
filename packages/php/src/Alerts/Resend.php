<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\Js;

/**
 * Sends alerts as email through Resend (alerts/resend.ts).
 * API reference: https://resend.com/docs/api-reference/emails/send-email
 * POST https://api.resend.com/emails with a bearer API key.
 *
 *     new Resend(apiKey: getenv('RESEND_API_KEY'), from: 'CronWatch <alerts@example.com>', to: 'ops@example.com')
 */
final class Resend implements AlertChannel
{
    private const ENDPOINT = 'https://api.resend.com/emails';

    private readonly string $apiKey;
    /** @var list<string> */
    private readonly array $to;
    private readonly ?\Closure $link;
    private readonly Http $http;

    /**
     * @param string|list<string> $to one address or several
     * @param string|null $subjectPrefix put in front of the title in the subject, "[prod]" say
     * @param (callable(Alert): string)|null $link link back to the job in your dashboard
     */
    public function __construct(
        #[\SensitiveParameter] mixed $apiKey,
        private readonly string $from,
        string|array $to,
        private readonly ?string $subjectPrefix = null,
        ?callable $link = null,
        ?Http $http = null,
    ) {
        // A pasted credential often carries a stray space or newline, which a header would refuse or send.
        $this->apiKey = Shared::required($apiKey, 'Resend needs an apiKey');
        $this->to = Email::recipients('Resend', $from, $to);
        $this->link = $link === null ? null : \Closure::fromCallable($link);
        $this->http = $http ?? Transport::default();
    }

    public function name(): string
    {
        return 'resend';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $email = Email::compose($alert, $this->from, $this->to, $this->subjectPrefix, $this->link);
        Shared::post($this->http, 'Resend', self::ENDPOINT, [
            'content-type' => 'application/json',
            'authorization' => "Bearer {$this->apiKey}",
            // The same alert sent twice within 24 hours is delivered once.
            'idempotency-key' => 'cronwatch-' . Shared::alertId($alert),
        ], Js::stringify(['from' => $email->from, 'to' => $email->to, 'subject' => $email->subject, 'text' => $email->text, 'html' => $email->html]), [$this->apiKey]);
    }
}
