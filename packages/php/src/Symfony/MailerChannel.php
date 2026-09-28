<?php

declare(strict_types=1);

namespace Cronwatch\Symfony;

use Cronwatch\Alert;
use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\Alerts\Email as Composed;
use Symfony\Component\Mailer\MailerInterface;
use Symfony\Component\Mime\Address;
use Symfony\Component\Mime\Email;

/**
 * Sends each alert through the app's mailer (symfony/mailer), composed as
 * every email channel composes it: the same subject, plain text and HTML.
 */
final class MailerChannel implements AlertChannel
{
    /** @var list<string> */
    private readonly array $to;
    private readonly ?\Closure $link;

    /** @param list<string>|string $to */
    public function __construct(
        private readonly MailerInterface $mailer,
        array|string $to,
        private readonly string $from,
        private readonly ?string $subjectPrefix = null,
        ?callable $link = null,
    ) {
        $this->to = Composed::recipients('MailerChannel', $from, $to);
        $this->link = $link === null ? null : \Closure::fromCallable($link);
    }

    public function name(): string
    {
        return 'mailer';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $composed = Composed::compose($alert, $this->from, $this->to, $this->subjectPrefix, $this->link);
        $email = (new Email())
            ->from(Address::create($composed->from))
            ->to(...array_map(fn (string $to) => Address::create($to), $composed->to))
            ->subject($composed->subject)
            ->text($composed->text)
            ->html($composed->html);
        $this->mailer->send($email);
    }
}
