<?php

declare(strict_types=1);

namespace Cronwatch\Craft;

use Cronwatch\Alert;
use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\Alerts\Email;
use Craft;

/**
 * Sends alerts as email through Craft's mailer, so they go however the site
 * sends its mail (the transport under Settings, Email). The subject, plain
 * text and HTML are the library's email channels' (Email::compose()); the
 * sender is Craft's system address.
 */
final class MailChannel implements AlertChannel
{
    /** @var list<string> */
    private readonly array $to;
    private readonly ?\Closure $link;

    /** @param list<string>|string $to */
    public function __construct(array|string $to, private readonly ?string $subjectPrefix = null, ?callable $link = null)
    {
        $this->to = array_values(array_filter(array_map('trim', is_array($to) ? $to : explode(',', $to)), fn (string $a) => $a !== ''));
        if ($this->to === []) {
            throw new \InvalidArgumentException('MailChannel needs at least one address');
        }
        $this->link = $link === null ? null : \Closure::fromCallable($link);
    }

    public function name(): string
    {
        return 'email';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $email = Email::compose($alert, '', $this->to, $this->subjectPrefix, $this->link);
        $sent = Craft::$app->getMailer()->compose()
            ->setTo($email->to)
            ->setSubject($email->subject)
            ->setTextBody($email->text)
            ->setHtmlBody($email->html)
            ->send();
        if (!$sent) {
            throw new \RuntimeException("Craft's mailer could not send the alert");
        }
    }
}
