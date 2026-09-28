<?php

declare(strict_types=1);

namespace Cronwatch\Alerts;

use Cronwatch\Alert;
use Cronwatch\Js;

/**
 * Sends alerts to a Discord channel through a webhook (alerts/discord.ts).
 *
 *     new Discord(webhookUrl: getenv('DISCORD_WEBHOOK_URL'))
 */
final class Discord implements AlertChannel
{
    private const COLOR = [
        'missed' => 0xb7791f,
        'failed' => 0xc62828,
        'stuck' => 0xc62828,
        'slow' => 0xb7791f,
        'over_budget' => 0xb7791f,
        'recovered' => 0x1f8a4c,
    ];

    private readonly ?\Closure $link;
    private readonly Http $http;

    /**
     * @param string $webhookUrl a channel webhook URL from Server Settings, Integrations, Webhooks
     * @param (callable(Alert): string)|null $link link back to the job in your dashboard
     */
    public function __construct(private readonly string $webhookUrl, ?callable $link = null, ?Http $http = null)
    {
        if ($webhookUrl === '') {
            throw new \InvalidArgumentException('Discord needs a webhookUrl');
        }
        $this->link = $link === null ? null : \Closure::fromCallable($link);
        $this->http = $http ?? Transport::default();
    }

    public function name(): string
    {
        return 'discord';
    }

    public function send(Alert $alert, ChannelContext $context): void
    {
        $url = Shared::link($this->link, $alert);
        $embed = ['title' => $alert->title];
        if ($url !== null) {
            $embed['url'] = $url;
        }
        $embed['description'] = "```\n" . self::codeBlockSafe(Js::slice16($alert->message, 3800)) . "\n```"
            . (Shared::present($alert->triage) ? "\n**Triage:** " . self::escapeMarkdown(Js::slice16((string) $alert->triage, 1000)) : '');
        $embed['color'] = self::COLOR[$alert->type] ?? null;
        $embed['timestamp'] = Js::iso($alert->at);
        $response = $this->http->post(Shared::postable($this->webhookUrl), Js::stringify([
            'content' => $alert->title,
            // Job output can hold anything, "@everyone" included; ping no one.
            'allowed_mentions' => ['parse' => []],
            'embeds' => [$embed],
        ]), ['content-type' => 'application/json']);
        if (!$response->ok()) {
            throw new \RuntimeException("Discord webhook answered {$response->status}: " . Js::head16($response->body, 200));
        }
    }

    /** Breaks up ``` so text inside a code block cannot close it. */
    public static function codeBlockSafe(string $text): string
    {
        return str_replace('```', "`\u{200B}`\u{200B}`", $text);
    }

    /** Escapes the characters Discord reads as markdown, links included. */
    public static function escapeMarkdown(string $text): string
    {
        return (string) preg_replace('/[\\\\`*_~|\[\]()<>]/', '\\\\$0', $text);
    }
}
