<?php

declare(strict_types=1);

namespace Drupal\cronwatch;

use Cronwatch\Alert;
use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\Alerts\Email;
use Drupal\Core\Language\LanguageManagerInterface;
use Drupal\Core\Mail\MailManagerInterface;

/**
 * Sends alerts as email through Drupal's mail system.
 *
 * So they go however the site sends its mail (PHP's mail(), or the SMTP or
 * mail service module it uses). The subject and plain text body are the
 * library's email channels' (Email::compose()), put into the message by
 * cronwatch_mail(); Drupal's mail system formats the body as it formats any
 * plain text mail. The sender is the site's own address.
 */
final class MailChannel implements AlertChannel {

  /**
   * The addresses, one or more.
   *
   * @var list<string>
   */
  private readonly array $to;

  private readonly ?\Closure $link;

  /**
   * @param list<string>|string $to
   *   The addresses, a list or comma separated.
   */
  public function __construct(
    private readonly MailManagerInterface $mail,
    private readonly LanguageManagerInterface $languages,
    array|string $to,
    private readonly ?string $subjectPrefix = NULL,
    ?callable $link = NULL,
  ) {
    $this->to = array_values(array_filter(array_map('trim', is_array($to) ? $to : explode(',', $to)), fn (string $a) => $a !== ''));
    if ($this->to === []) {
      throw new \InvalidArgumentException('MailChannel needs at least one address');
    }
    $this->link = $link === NULL ? NULL : \Closure::fromCallable($link);
  }

  /**
   * {@inheritdoc}
   */
  public function name(): string {
    return 'email';
  }

  /**
   * {@inheritdoc}
   */
  public function send(Alert $alert, ChannelContext $context): void {
    $email = Email::compose($alert, '', $this->to, $this->subjectPrefix, $this->link);
    $result = $this->mail->mail(
      'cronwatch',
      'alert',
      implode(', ', $email->to),
      $this->languages->getDefaultLanguage()->getId(),
      ['subject' => $email->subject, 'text' => $email->text],
      NULL,
      TRUE,
    );
    if (empty($result['result'])) {
      throw new \RuntimeException("Drupal's mail system could not send the alert");
    }
  }

}
