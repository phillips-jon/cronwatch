<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\Js;

/**
 * POSTs the alert as JSON to any URL (alerts/webhook.ts). The body is the
 * Alert: { type, run, details, job, definition, title, message, at, triage }.
 * With a secret, each request carries X-CronWatch-Signature: sha256=<hex>,
 * the HMAC-SHA256 of the raw body, so the receiver can verify it. A
 * redirect is an error: point the url at where the receiver really is.
 *
 *     new Webhook(url: 'https://hooks.example.com/cronwatch', secret: getenv('CRONWATCH_WEBHOOK_SECRET'))
 */
final class Webhook implements AlertChannel
{
    private readonly Http $http;

    /** @param array<string, string> $headers extra request headers, for an Authorization header say; values are trimmed */
    public function __construct(
        private readonly string $url,
        private readonly array $headers = [],
        private readonly ?string $secret = null,
        ?Http $http = null,
    ) {
        if ($url === '') {
            throw new \InvalidArgumentException('Webhook needs a url');
        }
        $this->http = $http ?? Transport::default();
    }

    public function name(): string
    {
        return 'webhook';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        // Sent as fetch sends a string: UTF-8, U+FFFD for bytes that are not,
        // so the signature is over exactly the bytes sent.
        $body = Js::wellFormed(Js::stringify($alert));
        $headers = ['content-type' => 'application/json', 'user-agent' => 'cronwatch'];
        // A pasted Authorization value often carries a stray space or newline, which fetch would refuse.
        foreach ($this->headers as $name => $value) {
            $headers[(string) $name] = is_string($value) ? Js::trim($value) : $value;
        }
        if (Shared::present($this->secret)) {
            $headers['x-cronwatch-signature'] = 'sha256=' . self::hmacSha256Hex((string) $this->secret, $body);
        }
        // A redirect is refused, not followed: the headers (and the signature) would go with it.
        $response = $this->http->post(Shared::postable($this->url), $body, $headers);
        // Only the origin: a webhook URL's path or query often is the credential.
        if (!$response->ok()) {
            throw new \RuntimeException('Webhook ' . Shared::origin($this->url) . " answered {$response->status}");
        }
    }

    /** HMAC-SHA256 of the body as lowercase hex. */
    public static function hmacSha256Hex(string $secret, string $body): string
    {
        return hash_hmac('sha256', Js::wellFormed($body), Js::wellFormed($secret));
    }
}
