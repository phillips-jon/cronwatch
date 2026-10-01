<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\AlertType;
use Cronwatch\Js;

/**
 * Texts alerts through Twilio (alerts/twilio.ts).
 * API reference: https://www.twilio.com/docs/messaging/api/message-resource
 * POST https://api.twilio.com/2010-04-01/Accounts/<AccountSid>/Messages.json,
 * form encoded, with basic auth. One recipient per request.
 *
 *     new Twilio(accountSid: getenv('TWILIO_ACCOUNT_SID'), authToken: getenv('TWILIO_AUTH_TOKEN'),
 *                from: '+15005550006', to: ['+15551110000'])
 *
 * Sign with authToken, or with apiKeySid and apiKeySecret. Send from a
 * number, or through messagingServiceSid. Recoveries are not texted unless
 * `recovered: true`: a text is for what needs a person. A message fits in
 * `segments` SMS segments (default 3, 1 to 10).
 *
 * The alert counts as delivered when any number took it; each number that
 * refused it is reported through the channel context (onError). It fails
 * only when every number did. The SDK texts the numbers at once; PHP texts
 * them one after another, in the order given, each request with its own ten
 * second deadline.
 */
final class Twilio implements AlertChannel
{
    /**
     * The most segments a message may use, which keeps it inside Twilio's 1600 character Body limit.
     *
     * @deprecated Internal to the Twilio channel, public by accident; removed in 1.0.
     */
    public const MAX_SEGMENTS = 10;
    /**
     * Twilio refuses a Body longer than this.
     *
     * @deprecated Internal to the Twilio channel, public by accident; removed in 1.0.
     */
    public const MAX_BODY = 1600;

    // The GSM 03.38 alphabet: a message in it takes 153 characters a segment
    // (when split), anything else is UCS-2 at 67. The extension table costs two.
    private const GSM = "@£\$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà";
    private const GSM_EXTENDED = "^{}\\[~]|€\f";

    /** @var array<string, int>|null each GSM character and the septets it takes */
    private static ?array $septets = null;

    /** @var list<string> */
    private readonly array $to;
    private readonly string $url;
    private readonly string $password;
    private readonly string $authorization;
    private readonly int $segments;
    private readonly ?\Closure $link;
    private readonly Http $http;

    /**
     * @param mixed $accountSid the account SID, "AC..."; it is in the URL whichever credentials sign the request
     * @param string|list<string> $to one number in E.164 form, or several; each gets its own message
     * @param mixed $segments how many SMS segments a message may use, 1 to 10; default 3
     */
    public function __construct(
        mixed $accountSid,
        string|array $to,
        #[\SensitiveParameter] mixed $authToken = null,
        #[\SensitiveParameter] mixed $apiKeySid = null,
        #[\SensitiveParameter] mixed $apiKeySecret = null,
        private readonly ?string $from = null,
        private readonly ?string $messagingServiceSid = null,
        private readonly bool $recovered = false,
        mixed $segments = 3,
        ?callable $link = null,
        ?Http $http = null,
    ) {
        // A pasted credential often carries a stray space or newline, which the Authorization header would refuse or send.
        $accountSid = Shared::required($accountSid, 'Twilio needs an accountSid');
        $keySid = Shared::trimmed($apiKeySid);
        $user = $keySid !== '' ? $keySid : $accountSid;
        $password = $keySid !== '' ? Shared::trimmed($apiKeySecret) : Shared::trimmed($authToken);
        if ($password === '') {
            throw new \InvalidArgumentException('Twilio needs an authToken, or an apiKeySid and apiKeySecret');
        }
        if (!Shared::present($from) && !Shared::present($messagingServiceSid)) {
            throw new \InvalidArgumentException('Twilio needs a from number or a messagingServiceSid');
        }
        $this->to = Shared::list($to);
        if ($this->to === []) {
            throw new \InvalidArgumentException('Twilio needs at least one to number');
        }
        $this->url = 'https://api.twilio.com/2010-04-01/Accounts/' . Shared::encodeUriComponent($accountSid) . '/Messages.json';
        $this->password = $password;
        $this->authorization = Shared::basicAuth($user, $password);
        $this->segments = self::segmentBudget($segments);
        $this->link = $link === null ? null : \Closure::fromCallable($link);
        $this->http = $http ?? Transport::default();
    }

    public function name(): string
    {
        return 'twilio';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        if ($alert->type === AlertType::RECOVERED && !$this->recovered) {
            return;
        }
        $body = self::smsBody($alert, Shared::link($this->link, $alert), $this->segments);
        $failed = [];
        foreach ($this->to as $number) {
            $pairs = [['To', $number]];
            $pairs[] = Shared::present($this->messagingServiceSid) ? ['MessagingServiceSid', (string) $this->messagingServiceSid] : ['From', (string) $this->from];
            $pairs[] = ['Body', $body];
            try {
                Shared::post($this->http, 'Twilio', $this->url, [
                    'content-type' => 'application/x-www-form-urlencoded',
                    'authorization' => $this->authorization,
                ], Shared::form($pairs), [$this->password]);
            } catch (\Throwable $error) {
                $failed[] = [$number, $error];
            }
        }
        if ($failed === []) {
            return;
        }
        $count = count($this->to);
        if (count($failed) === $count) {
            $message = $failed[0][1]->getMessage();
            throw new \RuntimeException($count > 1 ? "{$message} (" . count($failed) . " of {$count} numbers failed)" : $message);
        }
        // Delivered to someone: counted as sent, so a retry never texts the numbers that took it again.
        $took = $count - count($failed);
        foreach ($failed as [$number, $error]) {
            $context->onError(new \RuntimeException($error->getMessage() . ' (to ' . self::maskNumber($number) . "; {$took} of {$count} numbers took the alert)"));
        }
    }

    /**
     * A number with all but its last four digits hidden, for an error message.
     *
     * @deprecated Internal to the Twilio channel, public by accident; removed in 1.0.
     */
    public static function maskNumber(string $number): string
    {
        $length = Js::length16($number);
        return $length <= 4 ? $number : str_repeat('*', min($length - 4, 8)) . Js::tail16($number, 4);
    }

    /**
     * A segment count clamped to 1 to MAX_SEGMENTS; 3 for anything not a number.
     *
     * @deprecated Internal to the Twilio channel, public by accident; removed in 1.0.
     */
    public static function segmentBudget(mixed $segments): int
    {
        $n = Js::isFinite($segments) ? (int) floor($segments) : 3;
        return min(self::MAX_SEGMENTS, max(1, $n));
    }

    /** @return list<string> the code points of a string */
    private static function chars(string $text): array
    {
        return $text === '' ? [] : (preg_split('//u', $text, -1, PREG_SPLIT_NO_EMPTY) ?: []);
    }

    /**
     * The segments `text` takes. A character is never split across two: an
     * extension character (two septets) or a surrogate pair (two UCS-2
     * units) that would straddle a boundary starts the next segment, as
     * phones pack them.
     *
     * @deprecated Internal to the Twilio channel, public by accident; removed in 1.0.
     */
    public static function smsSegments(string $text): int
    {
        if (self::$septets === null) {
            self::$septets = array_fill_keys(self::chars(self::GSM), 1) + array_fill_keys(self::chars(self::GSM_EXTENDED), 2);
        }
        $chars = self::chars($text);
        $sizes = [];
        $gsm = true;
        foreach ($chars as $ch) {
            if (!isset(self::$septets[$ch])) {
                $gsm = false;
                break;
            }
            $sizes[] = self::$septets[$ch];
        }
        [$single, $per] = $gsm ? [160, 153] : [70, 67];
        if (!$gsm) {
            $sizes = array_map(fn (string $ch) => strlen($ch) === 4 ? 2 : 1, $chars);
        }
        if (array_sum($sizes) <= $single) {
            return 1;
        }
        $count = 1;
        $used = 0;
        foreach ($sizes as $u) {
            if ($used + $u > $per) {
                $count++;
                $used = 0;
            }
            $used += $u;
        }
        return $count;
    }

    /**
     * Whether `text` fits in `segments` SMS segments and Twilio's Body limit.
     *
     * @deprecated Internal to the Twilio channel, public by accident; removed in 1.0.
     */
    public static function fits(string $text, int $segments): bool
    {
        return Js::length16($text) <= self::MAX_BODY && self::smsSegments($text) <= $segments;
    }

    /**
     * The title, then as many lines of the message (and the triage) as fit,
     * then the link. The link is kept whole; the text before it is cut to
     * make room. `segments` is clamped to 1 to 10.
     *
     * @deprecated Internal to the Twilio channel, public by accident; removed in 1.0.
     */
    public static function smsBody(Alert $alert, ?string $link, mixed $segments = 3): string
    {
        $budget = self::segmentBudget($segments);
        $tail = Shared::present($link) ? "\n{$link}" : '';
        $lines = [$alert->title];
        foreach (explode("\n", $alert->message) as $line) {
            if (Js::trim($line) !== '') {
                $lines[] = $line;
            }
        }
        if (Shared::present($alert->triage)) {
            $lines[] = "Triage: {$alert->triage}";
        }
        $text = '';
        foreach ($lines as $line) {
            $next = $text !== '' ? "{$text}\n{$line}" : $line;
            if (self::fits($next . $tail, $budget)) {
                $text = $next;
                continue;
            }
            // Part of this line, cut on a code point and marked.
            $chars = self::chars($line);
            $lo = 0;
            $hi = count($chars);
            while ($lo < $hi) {
                $mid = intdiv($lo + $hi + 1, 2);
                $candidate = ($text !== '' ? "{$text}\n" : '') . implode('', array_slice($chars, 0, $mid)) . '...';
                if (self::fits($candidate . $tail, $budget)) {
                    $lo = $mid;
                } else {
                    $hi = $mid - 1;
                }
            }
            if ($lo > 0) {
                $text = ($text !== '' ? "{$text}\n" : '') . implode('', array_slice($chars, 0, $lo)) . '...';
            }
            break;
        }
        // Only a link too long for any budget gets here too long; Twilio would refuse it whole.
        return Shared::cut($text . $tail, self::MAX_BODY);
    }
}
