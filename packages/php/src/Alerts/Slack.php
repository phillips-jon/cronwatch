<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\Js;

/**
 * Sends alerts to a Slack channel through an incoming webhook (alerts/slack.ts).
 *
 *     new Slack(webhookUrl: getenv('SLACK_WEBHOOK_URL'), link: fn (Alert $a) => "https://app.example.com/cronwatch/jobs/{$a->job}")
 */
final class Slack implements AlertChannel
{
    private const EMOJI = [
        'missed' => ':hourglass_flowing_sand:',
        'failed' => ':x:',
        'stuck' => ':no_entry:',
        'slow' => ':turtle:',
        'over_budget' => ':moneybag:',
        'recovered' => ':white_check_mark:',
    ];

    private readonly ?\Closure $link;
    private readonly Http $http;

    /**
     * @param string $webhookUrl an incoming webhook URL from api.slack.com/messaging/webhooks
     * @param (callable(Alert): string)|null $link link back to the job in your dashboard
     */
    public function __construct(private readonly string $webhookUrl, ?callable $link = null, ?Http $http = null)
    {
        if ($webhookUrl === '') {
            throw new \InvalidArgumentException('Slack needs a webhookUrl');
        }
        $this->link = $link === null ? null : \Closure::fromCallable($link);
        $this->http = $http ?? NativeHttp::default();
    }

    public function name(): string
    {
        return 'slack';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $url = Shared::link($this->link, $alert);
        $title = (self::EMOJI[$alert->type] ?? 'undefined') . ' *' . self::escape($alert->title) . '*' . ($url !== null ? " (<{$url}|open>)" : '');
        $body = Js::slice16(self::codeBlockSafe(self::escape($alert->message)), 2900);
        $blocks = [
            ['type' => 'section', 'text' => ['type' => 'mrkdwn', 'text' => $title]],
            ['type' => 'section', 'text' => ['type' => 'mrkdwn', 'text' => '```' . $body . '```']],
        ];
        // Its own block, so a long diagnosis cannot push a block past Slack's 3000 character limit.
        if (Shared::present($alert->triage)) {
            $blocks[] = ['type' => 'section', 'text' => ['type' => 'mrkdwn', 'text' => Js::slice16('_Triage:_ ' . self::escape((string) $alert->triage), 3000)]];
        }
        $response = $this->http->post($this->webhookUrl, Js::stringify([
            // The notification fallback is parsed as mrkdwn too, so it is escaped like the blocks.
            'text' => self::escape("{$alert->title}\n{$alert->message}"),
            'blocks' => $blocks,
        ]), ['content-type' => 'application/json']);
        if (!$response->ok()) {
            throw new \RuntimeException("Slack webhook answered {$response->status}: " . Js::head16($response->body, 200));
        }
    }

    /** Slack's three control characters. Escaping < and > also stops <!channel> and <url|links>. */
    private static function escape(string $text): string
    {
        return strtr($text, ['&' => '&amp;', '<' => '&lt;', '>' => '&gt;']);
    }

    /** Breaks up ``` so text inside a code block cannot close it. */
    private static function codeBlockSafe(string $text): string
    {
        return str_replace('```', "`\u{200B}`\u{200B}`", $text);
    }
}
