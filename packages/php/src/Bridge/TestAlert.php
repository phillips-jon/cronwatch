<?php

declare(strict_types=1);

namespace Cronwatch\Bridge;

use Cronwatch\Alert;
use Cronwatch\AlertType;
use Cronwatch\Alerts\AlertChannel;
use Cronwatch\Alerts\ChannelContext;
use Cronwatch\Alerts\Custom;
use Cronwatch\JobDefinition;
use Cronwatch\Js;

/**
 * The test alert a settings page sends: one alert, "CronWatch test alert",
 * to each channel in turn, with what each answered, so the owner sees which
 * channel works and why one does not. Nothing is stored. The WordPress
 * plugin sends the same alert with WordPress's functions.
 *
 * @internal For the framework integrations.
 */
final class TestAlert
{
    public const JOB = 'cronwatch-test';

    public static function alert(string $site): Alert
    {
        return new Alert(
            type: AlertType::FAILED,
            run: null,
            details: [],
            job: self::JOB,
            definition: new JobDefinition(['name' => self::JOB]),
            title: 'CronWatch test alert',
            message: "A test alert from {$site}. If you can read this, CronWatch alerts reach you.",
            at: Js::nowMs(),
        );
    }

    /**
     * @param list<AlertChannel|callable> $channels
     * @return list<array{channel: string, ok: bool, message: string}>
     */
    public static function send(array $channels, string $site): array
    {
        $alert = self::alert($site);
        $results = [];
        foreach ($channels as $channel) {
            $channel = $channel instanceof AlertChannel ? $channel : new Custom('custom', $channel);
            $problems = [];
            try {
                $channel->send($alert, new ChannelContext(function (\Throwable $e) use (&$problems): void {
                    $problems[] = $e->getMessage();
                }));
                $results[] = ['channel' => $channel->name(), 'ok' => true, 'message' => implode('; ', $problems)];
            } catch (\Throwable $error) {
                $results[] = ['channel' => $channel->name(), 'ok' => false, 'message' => $error->getMessage()];
            }
        }
        return $results;
    }
}
