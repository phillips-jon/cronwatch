<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\Js;

/**
 * Sends alerts as email through Amazon SES, API v2 SendEmail (alerts/ses.ts).
 * API reference: https://docs.aws.amazon.com/ses/latest/APIReference-V2/API_SendEmail.html
 * POST https://email.<region>.amazonaws.com/v2/email/outbound-emails, signed
 * with AWS Signature Version 4 (SigV4), so no AWS SDK is needed.
 */
final class Ses implements AlertChannel
{
    private readonly string $accessKeyId;
    private readonly string $secretAccessKey;
    private readonly ?string $sessionToken;
    /** @var list<string> */
    private readonly array $to;
    private readonly string $url;
    private readonly ?\Closure $link;
    private readonly \Closure $now;
    private readonly Http $http;

    /**
     * @param string $region the SES region, "us-east-1" say; the from identity must be verified there
     * @param mixed $sessionToken for temporary credentials, an assumed role say
     * @param string|null $configurationSetName a configuration set for event publishing, if you use one
     * @param string|list<string> $to
     * @param (callable(): (int|float))|null $now the clock used to sign requests, in epoch milliseconds; for tests
     */
    public function __construct(
        private readonly string $region,
        #[\SensitiveParameter] mixed $accessKeyId,
        #[\SensitiveParameter] mixed $secretAccessKey,
        private readonly string $from,
        string|array $to,
        #[\SensitiveParameter] mixed $sessionToken = null,
        private readonly ?string $configurationSetName = null,
        private readonly ?string $subjectPrefix = null,
        ?callable $link = null,
        ?callable $now = null,
        ?Http $http = null,
    ) {
        if ($region === '') {
            throw new \InvalidArgumentException('Ses needs a region');
        }
        if (preg_match('/^[a-z0-9-]+$/D', $region) !== 1) {
            throw new \InvalidArgumentException('Ses needs a region like us-east-1');
        }
        // A pasted credential often carries a stray space or newline, which would spoil the signature.
        $this->accessKeyId = Shared::trimmed($accessKeyId);
        $this->secretAccessKey = Shared::trimmed($secretAccessKey);
        $token = Shared::trimmed($sessionToken);
        $this->sessionToken = $token === '' ? null : $token;
        if ($this->accessKeyId === '' || $this->secretAccessKey === '') {
            throw new \InvalidArgumentException('Ses needs an accessKeyId and secretAccessKey');
        }
        $this->to = Email::recipients('Ses', $from, $to);
        $this->url = "https://email.{$region}.amazonaws.com/v2/email/outbound-emails";
        $this->link = $link === null ? null : \Closure::fromCallable($link);
        $this->now = $now === null ? Js::nowMs(...) : \Closure::fromCallable($now);
        $this->http = $http ?? Transport::default();
    }

    public function name(): string
    {
        return 'ses';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $email = Email::compose($alert, $this->from, $this->to, $this->subjectPrefix, $this->link);
        $request = [
            'FromEmailAddress' => $email->from,
            'Destination' => ['ToAddresses' => $email->to],
            'Content' => [
                'Simple' => [
                    'Subject' => ['Data' => $email->subject, 'Charset' => 'UTF-8'],
                    'Body' => ['Text' => ['Data' => $email->text, 'Charset' => 'UTF-8'], 'Html' => ['Data' => $email->html, 'Charset' => 'UTF-8']],
                ],
            ],
        ];
        if (Shared::present($this->configurationSetName)) {
            $request['ConfigurationSetName'] = $this->configurationSetName;
        }
        $request['EmailTags'] = [['Name' => 'source', 'Value' => 'cronwatch']];
        // Signed as sent: UTF-8, U+FFFD for bytes that are not (Shared::post sends it so).
        $body = Js::wellFormed(Js::stringify($request));
        $headers = SigV4::sign(
            'POST', $this->url, ['content-type' => 'application/json'], $body, $this->region, 'ses', ($this->now)(),
            $this->accessKeyId, $this->secretAccessKey, $this->sessionToken,
        );
        Shared::post($this->http, 'SES', $this->url, $headers, $body, [$this->secretAccessKey, $this->sessionToken]);
    }
}
