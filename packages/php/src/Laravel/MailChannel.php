<?php

declare(strict_types=1);

namespace Cronwatch\Laravel;

use Cronwatch\Alert;
use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\Alerts\Email;

/**
 * Sends each alert through the app's mailer (config/mail.php), composed as
 * every email channel composes it: the same subject, plain text, and HTML.
 * The from address defaults to the mailer's (mail.from).
 */
final class MailChannel implements AlertChannel
{
    /** @var list<string> */
    private readonly array $to;
    private readonly ?\Closure $link;

    /** @param list<string>|string $to */
    public function __construct(
        private readonly object $mail,
        array|string $to,
        private readonly ?string $from = null,
        private readonly ?string $mailer = null,
        private readonly ?string $subjectPrefix = null,
        ?callable $link = null,
    ) {
        $this->to = array_values(array_filter(array_map('trim', is_array($to) ? $to : explode(',', $to)), fn (string $a) => $a !== ''));
        if ($this->to === []) {
            throw new \InvalidArgumentException('MailChannel needs at least one to address');
        }
        $this->link = $link === null ? null : \Closure::fromCallable($link);
    }

    public function name(): string
    {
        return 'mail';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $email = Email::compose($alert, (string) $this->from, $this->to, $this->subjectPrefix, $this->link);
        $from = $this->from;
        $this->mail->mailer($this->mailer)->send([], [], function (object $message) use ($email, $from): void {
            $message->to($email->to)->subject($email->subject);
            if ($from !== null && $from !== '') {
                $address = Email::parseAddress($from);
                $message->from($address['email'], $address['name'] ?? null);
            }
            $message->text($email->text)->html($email->html);
        });
    }
}
