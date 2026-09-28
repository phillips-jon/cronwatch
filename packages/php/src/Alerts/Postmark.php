<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\Js;

/**
 * Sends alerts as email through Postmark (alerts/postmark.ts).
 * API reference: https://postmarkapp.com/developer/api/email-api
 * POST https://api.postmarkapp.com/email with X-Postmark-Server-Token.
 */
final class Postmark implements AlertChannel
{
    private const ENDPOINT = 'https://api.postmarkapp.com/email';

    private readonly string $serverToken;
    /** @var list<string> */
    private readonly array $to;
    private readonly ?\Closure $link;
    private readonly Http $http;

    /**
     * @param mixed $serverToken a server API token, from the server's API Tokens tab
     * @param string|list<string> $to
     * @param string|null $messageStream default "outbound", the transactional stream
     */
    public function __construct(
        mixed $serverToken,
        private readonly string $from,
        string|array $to,
        private readonly ?string $messageStream = null,
        private readonly ?string $subjectPrefix = null,
        ?callable $link = null,
        ?Http $http = null,
    ) {
        // A pasted credential often carries a stray space or newline, which a header would refuse or send.
        $this->serverToken = Shared::required($serverToken, 'Postmark needs a serverToken');
        $this->to = Email::recipients('Postmark', $from, $to);
        $this->link = $link === null ? null : \Closure::fromCallable($link);
        $this->http = $http ?? NativeHttp::default();
    }

    public function name(): string
    {
        return 'postmark';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $email = Email::compose($alert, $this->from, $this->to, $this->subjectPrefix, $this->link);
        Shared::post($this->http, 'Postmark', self::ENDPOINT, [
            'content-type' => 'application/json',
            'accept' => 'application/json',
            'x-postmark-server-token' => $this->serverToken,
        ], Js::stringify([
            'From' => $email->from,
            'To' => implode(', ', $email->to),
            'Subject' => $email->subject,
            'TextBody' => $email->text,
            'HtmlBody' => $email->html,
            'MessageStream' => $this->messageStream ?? 'outbound',
            'Tag' => 'cronwatch',
        ]), [$this->serverToken]);
    }
}
