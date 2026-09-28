<?php

declare(strict_types=1);

namespace Cronwatch\WordPress;

\defined('ABSPATH') || exit;

use Cronwatch\Alert;
use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\Alerts\Email;

/**
 * Sends alerts as email through wp_mail(), so they go however the site
 * sends its mail (an SMTP plugin, a mail service's plugin, or PHP's mail()).
 * The subject and plain text body are the library's email channels', from
 * Email::compose(). The sender is the site's usual one unless `from` is set.
 */
final class WpMail implements AlertChannel
{
    /** @var list<string> */
    private readonly array $to;
    private readonly ?\Closure $link;

    /** @param list<string>|string $to */
    public function __construct(array|string $to, private readonly ?string $from = null, private readonly ?string $subjectPrefix = null, ?callable $link = null)
    {
        $this->to = array_values(array_filter(array_map('trim', is_array($to) ? $to : explode(',', $to)), fn (string $a) => $a !== ''));
        if ($this->to === []) {
            throw new \InvalidArgumentException('WpMail needs at least one to address');
        }
        $this->link = $link === null ? null : \Closure::fromCallable($link);
    }

    public function name(): string
    {
        return 'email';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $email = Email::compose($alert, (string) $this->from, $this->to, $this->subjectPrefix, $this->link);
        $headers = ['Content-Type: text/plain; charset=UTF-8'];
        if ($this->from !== null && $this->from !== '') {
            $headers[] = 'From: ' . str_replace(["\r", "\n"], '', $this->from);
        }
        $failure = null;
        $listen = function ($error) use (&$failure): void {
            $failure = $error instanceof \WP_Error ? $error->get_error_message() : null;
        };
        add_action('wp_mail_failed', $listen);
        try {
            $sent = wp_mail($email->to, $email->subject, $email->text, $headers);
        } finally {
            remove_action('wp_mail_failed', $listen);
        }
        if (!$sent) {
            throw new \RuntimeException('wp_mail could not send the alert' . ($failure !== null && $failure !== '' ? ": {$failure}" : ''));
        }
    }
}
